(defpackage :s-sql
  (:use :common-lisp)
  (:export :smallint
           :bigint
           :numeric
           :real
           :double-precision
           :bytea
           :text
           :varchar
           :db-null
           :sql-type-name
           :sql-escape-string
           :from-sql-name
           :to-sql-name
           :sql-ize
           :*escape-sql-names-p*
           :sql
           :sql-compile
           :enable-s-sql-syntax))

(in-package :s-sql)

;; Utils

(defun strcat (&rest args)
  "Concatenate a list of strings into a single one."
  (let ((result (make-string (reduce #'+ args :initial-value 0 :key 'length))))
    (loop :for pos = 0 :then (+ pos (length arg))
          :for arg :in args
          :do (replace result arg :start1 pos))
    result))

(defun implode (sep list)
  "Reduce a list of strings to a single string, inserting a separator
between them."
  (apply 'strcat
         (loop :for element :on list
               :collect (car element)
               :if (cdr element)
               :collect sep)))

(defun split-on-keywords% (shape list)
  "Helper function for split-on-keywords. Extracts the values
associated with the keywords from an argument list, and checks for
errors."
  (let ((result ()))
    (labels ((next-word (words values)
               (if words
                   (let* ((me (intern (symbol-name (caar words)) :keyword))
                          (optional (member '? (car words)))
                          (multi (member '* (car words)))
                          (found (position me values)))
                     (cond (found
                            (let ((after-me (nthcdr (1+ found) values)))
                              (unless after-me
                                (error "Keyword ~A encountered at end of arguments." me))
                              (let ((next (next-word (cdr words) (cdr after-me))))
                                (unless (or multi (= next 0))
                                  (error "Too many arguments to keyword ~A." me))
                                (push (cons (caar words) (subseq after-me 0 (1+ next))) result)
                                found)))
                           (optional
                            (next-word (cdr words) values))
                           (t (error "Required keyword ~A not found." me))))
                   (length values))))
      (unless (= (next-word shape list) 0)
        (error "Arguments do not start with a valid keyword."))
      result)))

(defmacro split-on-keywords (words form &body body)
  "Used to handle arguments to some complex SQL operations. Arguments
are divided by keywords, which are interned with the name of the
non-keyword symbols in words, and bound to these symbols. After the
naming symbols, a ? can be used to indicate this argument group is
optional, and an + to indicate it can consist of more than one
element."
  (let ((alist (gensym)))
    `(let* ((,alist (split-on-keywords% ',words ,form))
            ,@(mapcar (lambda (word)
                        `(,(first word) (cdr (assoc ',(first word) ,alist))))
                      words))
        ,@body)))

;; Converting between symbols and SQL strings.

(defun make-sql-name (sym)
  "Convert a Lisp symbol into a name that can be an sql table, column,
or operation name."
  (cond ((eq sym '*) "*") ;; Special case
        ((and (> (length (symbol-name sym)) 1) ;; Placeholders like $2
              (char= (char (symbol-name sym) 0) #\$)
              (every #'digit-char-p (subseq (symbol-name sym) 1)))
         (symbol-name sym))
        (t (flet ((allowed-char (x)
                    (or (alphanumericp x) (eq x #\.))))
             (let ((name (string-downcase (symbol-name sym))))
               (dotimes (i (length name))
                 (unless (allowed-char (char name i))
                   (setf (char name i) #\_)))
               name)))))

(defparameter *escape-sql-names-p* nil
  "Setting this to T will make S-SQL add double quotes around
identifiers in queries, making it possible to use keywords like 'from'
or 'user' as column names \(at the cost of uglier queries).")

(defun add-quotes (name)
  "Add double quotes to around SQL identifier and around every dot in
it, for escaping table and column names."
  (loop :for dot = (position #\. name) :then (position #\. name :start (+ 2 dot))
        :while dot
        :do (setf name (format nil "~A\".\"~A"
                               (subseq name 0 dot)
                               (subseq name (1+ dot)))))
  (format nil "\"~A\"" name))

(defun to-sql-name (sym)
  "Convert a symbol to an SQL identifier, taking *escape-sql-names*
into account."
  (let ((name (make-sql-name sym)))
    (if *escape-sql-names-p*
        (add-quotes name)
        name)))

(defun from-sql-name (str)
  "Convert a string to something that might have been its original
lisp name \(does not work if this name contained non-alphanumeric
characters other than #\-)"
  (intern (map 'string (lambda (x) (if (eq x #\_) #\- x)) (string-upcase str)) (find-package :keyword)))

;; Writing out SQL type identifiers.

;; Aliases for some types that can be expressed in SQL.
(deftype smallint ()
  '(signed-byte 16))
(deftype bigint ()
  `(signed-byte 64))
(deftype numeric (&optional precision/scale scale)
  (declare (ignore precision/scale scale))
  'number)
(deftype double-precision ()
  'double-float)
(deftype bytea ()
  '(array (unsigned-byte 8)))
(deftype text ()
  'string)
(deftype varchar (length)
  `(string ,length))

(deftype db-null ()
  "Type for representing NULL values. Use like \(or integer db-null)
for declaring a type to be an integer that may be null."
  '(eql :null))

;; For types integer and real, the Lisp type isn't quite the same as
;; the SQL type. Close enough though.

(defgeneric sql-type-name (lisp-type &rest args)
  (:documentation "Transform a lisp type into a string containing
something SQL understands. Default is to just use the type symbol's
name.")
  (:method ((lisp-type symbol) &rest args)
    (declare (ignore args))
    (symbol-name lisp-type))
  (:method ((lisp-type (eql 'string)) &rest args)
    (cond (args (format nil "VARCHAR(~A)" (car args)))
          (t "TEXT")))
  (:method ((lisp-type (eql 'varchar)) &rest args)
    (cond (args (format nil "VARCHAR(~A)" (car args)))
          (t "VARCHAR")))
  (:method ((lisp-type (eql 'numeric)) &rest args)
    (cond ((cdr args)
           (destructuring-bind (precision scale) args
             (format nil "NUMERIC(~d, ~d)" precision scale)))
          (args (format nil "NUMERIC(~d)" (car args)))
          (t "NUMERIC")))
  (:method ((lisp-type (eql 'float)) &rest args)
    (declare (ignore args))
    "REAL")
  (:method ((lisp-type (eql 'double-float)) &rest args)
    (declare (ignore args))
    "DOUBLE PRECISION")
  (:method ((lisp-type (eql 'double-precision)) &rest args)
    (declare (ignore args))
    "DOUBLE PRECISION"))

(defun to-type-name (type)
  "Turn a Lisp type expression into an SQL typename."
  (if (listp type)
      (apply 'sql-type-name type)
      (sql-type-name type)))

;; Turning lisp values into SQL strings.

(defun sql-escape-string (string)
  "Escape string data so it can be used in a query."
  (with-output-to-string (out)
    (princ #\' out)
    (loop :for char :across string
          :do (princ (case char
                       (#\' "''")
                       ;; Turn off postgres' backslash behaviour to
                       ;; prevent unexpected strangeness.
                       (#\\ "\\\\")
                       (t char)) out))
    (princ #\' out)))

(defgeneric sql-ize (arg)
  (:documentation "Turn a lisp value into a string containing its SQL
representation. Returns an optional second value that indicates
whether the string should be escaped before being put into a query.")
  (:method ((arg string))
    (values arg t))
  (:method ((arg vector))
    (assert (typep arg '(vector (unsigned-byte 8))))
    (values (escape-bytes arg) t))
  (:method ((arg integer))
    (princ-to-string arg))
  (:method ((arg float))
    (format nil "~f" arg))
  (:method ((arg ratio))
    (format nil "~f" arg))
  (:method ((arg symbol))
    (to-sql-name arg))
  (:method ((arg (eql t)))
    "true")
  (:method ((arg (eql nil)))
    "false")
  (:method ((arg (eql :null)))
    "NULL")
  (:method ((arg simple-date:date))
    (multiple-value-bind (year month day) (simple-date:decode-date arg)
      (values (format nil "~4,'0d-~2,'0d-~2,'0d" year month day) t)))
  (:method ((arg simple-date:timestamp))
    (multiple-value-bind (year month day hour min sec ms)
        (simple-date:decode-timestamp arg)
      (values
       (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d~@[.~3,'0d~]"
               year month day hour min sec (if (zerop ms) nil ms))
       t)))
  (:method ((arg simple-date:interval))
    (multiple-value-bind (year month day hour min sec ms)
        (simple-date:decode-interval arg)
      (flet ((not-zero (x) (if (zerop x) nil x)))
        (values
         (format nil "~@[~d years ~]~@[~d months ~]~@[~d days ~]~@[~d hours ~]~@[~d minutes ~]~@[~d seconds ~]~@[~d milliseconds~]"
                 (not-zero year) (not-zero month) (not-zero day)
                 (not-zero hour) (not-zero min) (not-zero sec) (not-zero ms))
         t))))
  (:method ((arg t))
    (error "Value ~S can not be converted to an SQL literal." arg)))

(defun escape-bytes (bytes)
  "Escape an array of octets in PostgreSQL's horribly inefficient
textual format for binary data."
  (with-output-to-string (out)
    (loop :for byte fixnum :across bytes
          :do (if (or (< byte 32) (> byte 126) (= byte 39) (= byte 92))
                  (format out "\\~3,'0o" byte)
                  (princ (code-char byte) out)))))

(defun sql-ize-escaped (value)
  "Get the representation of a Lisp value so that it can be used in a
query."
  (multiple-value-bind (string escape) (sql-ize value)
    (if escape
        (sql-escape-string string)
        string)))

(defparameter *expand-runtime* nil)

(defun sql-expand (arg)
  "Compile-time expansion of forms into lists of stuff that evaluates
to strings \(which will form an SQL query when concatenated)."
  (cond ((and (consp arg) (keywordp (first arg)))
         (expand-sql-op (car arg) (cdr arg)))
        ((and (consp arg) *expand-runtime*)
         (expand-sql-op (intern (symbol-name (car arg)) :keyword) (cdr arg)))
        (*expand-runtime*
         (list (sql-ize-escaped arg)))
        ((and (consp arg) (eq (first arg) 'quote))
         (list (sql-ize-escaped (second arg))))
        ((or (consp arg) (and (symbolp arg) (not (keywordp arg))))
         (list `(sql-ize-escaped ,arg)))
        (t (list (sql-ize-escaped arg)))))

(defun sql-expand-list (elts &optional (sep ", "))
  "Expand a list of elements, adding a separator in between them."
  (loop :for elt :on elts
        :append (sql-expand (car elt))
        :if (cdr elt)
        :collect sep))

(defun reduce-strings (list)
  "Join adjacent strings in a list, leave other values intact."
  (let ((accum ())
        (span ""))
    (dolist (part list)
      (cond ((stringp part) (setf span (concatenate 'string span part)))
            (t (when (not (string= "" span))
                 (push span accum)
                 (setf span ""))
               (push part accum))))
    (if (not (string= "" span))
        (push span accum))
    (nreverse accum)))

(defmacro sql (form)
  "Compile form to an sql expression as far as possible."
  (let ((list (reduce-strings (sql-expand form))))
    (if (= 1 (length list))
        (car list)
        `(strcat ,@list))))
  
(defun sql-compile (form)
  (let ((*expand-runtime* t))
    (car (reduce-strings (sql-expand form)))))

;; The reader syntax.

(defun s-sql-reader (stream char min-args)
  (declare (ignore char min-args))
  (list 'sql (read stream)))

(defun enable-s-sql-syntax (&optional (char #\Q))
  "Enable a syntactic shortcut #Q\(...) for \(sql \(...)). Optionally
takes a character to use instead of #\\Q."
  (set-dispatch-macro-character #\# char 's-sql-reader))

;; Definitions of sql operations

(defgeneric expand-sql-op (op args)
  (:documentation "For overriding expansion of operators. Default is
to just place operator name in front, arguments between parentheses
behind it.")
  (:method ((op t) args)
    `(,(to-sql-name op) "(" ,@(sql-expand-list args) ")")))

(defmacro def-sql-op (name arglist &body body)
  "Macro to make defining syntax a bit more straightforward. Name
should be the keyword identifying the operator, arglist a lambda list
to apply to the arguments, and body something that produces a list of
strings and forms that evaluate to strings."
  (let ((args-name (gensym)))
    `(defmethod expand-sql-op ((op (eql ,name)) ,args-name)
      (destructuring-bind ,arglist ,args-name
        ,@body))))

(defun expand-infix-op (operator allow-unary args)
  (if (cdr args)
      `("(" ,@(sql-expand-list args (strcat " " operator " ")) ")")
      (if allow-unary
          (sql-expand (first args))
          (error "SQL operator ~A takes at least two arguments." operator))))

(defmacro def-infix-ops (allow-unary &rest ops)
  `(progn
    ,@(mapcar (lambda (op)
                `(defmethod expand-sql-op ((op (eql ,op)) args)
                  (expand-infix-op ,(string-downcase (symbol-name op)) ,allow-unary args)))
              ops)))
(def-infix-ops t :+ :* :& :|\|| :and :or :union)
(def-infix-ops nil := :/ :!= :< :> :<= :>= :^ :intersect :except :~* :!~ :!~* :like :ilike)

(def-sql-op :- (first &rest rest)
  (if rest
      (expand-infix-op "-" nil (cons first rest))
      `("(-" ,@(sql-expand first) ")")))
      
(def-sql-op :~ (first &rest rest)
  (if rest
      (expand-infix-op "-" nil (cons first rest))
      `("(~" ,@(sql-expand first) ")")))

(def-sql-op :not (arg)
  `("(not " ,@(sql-expand arg) ")"))

(def-sql-op :desc (arg)
  `(,@(sql-expand arg) " DESC"))

(def-sql-op :as (form name)
  `(,@(sql-expand form) " AS " ,@(sql-expand name)))

(def-sql-op :exists (query)
  `("(EXISTS " ,@(sql-expand query) ")"))

(def-sql-op :is-null (arg)
  `("(" ,@(sql-expand arg) " IS NULL)"))

(def-sql-op :in (form set)
  `("(" ,@(sql-expand form) " IN " ,@(sql-expand set) ")"))

(def-sql-op :not-in (form set)
  `("(" ,@(sql-expand form) " NOT IN " ,@(sql-expand set) ")"))

;; This one has two interfaces. When the elements are known at
;; compile-time, they can be given as multiple arguments to the
;; operator. When they are not, a single argument that evaulates to a
;; list should be used.
(def-sql-op :set (&rest elements)
  (if (not elements)
      '("(NULL)")
      (let ((expanded (sql-expand-list elements)))
        ;; Ugly way to check if everything was expanded
        (if (stringp (car expanded))
            `("(" ,@expanded ")")
            `("(" (implode ", " (mapcar 'sql-ize-escaped ,(car elements))) ")")))))

(def-sql-op :dot (&rest args)
  (sql-expand-list args "."))

(def-sql-op :type (value type)
  `(,@(sql-expand value) "::" ,(to-type-name type)))

(def-sql-op :raw (sql)
  (list sql))

(defun expand-joins (args)
  "Helper for the select operator. Turns the part following :from into
the proper SQL syntax for joining tables."
  (labels ((is-join (x) (member x '(:left-join :right-join :inner-join :cross-join))))
    (when (null args)
      (error "Empty :from clause in select"))
    (when (is-join (car args))
      (error ":from clause starts with a join: ~A" args))
    (loop :for table :on args
          :for first = t :then nil
          :append (cond ((is-join (car table))
                         (destructuring-bind (join name on clause) (subseq table 0 4)
                           (setf table (cdddr table))
                           (unless (and (eq on :on) clause)
                             (error "Incorrect join form in select."))
                           `(" " ,(ecase join
                                         (:left-join "LEFT") (:right-join "RIGHT")
                                         (:inner-join "INNER") (:cross-join "CROSS"))
                             " JOIN " ,@(sql-expand name)
                             " ON " ,@(sql-expand clause))))
                         (t `(,@(if first () '(", ")) ,@(sql-expand (car table))))))))

(def-sql-op :select (&rest args)
  (split-on-keywords ((vars *) (from * ?) (where ?) (group-by * ?) (having ?)) (cons :vars args)
    `("(SELECT " ,@(sql-expand-list vars)
      ,@(if from (cons " FROM " (expand-joins from)) ())
      ,@(if where (cons " WHERE " (sql-expand (car where))) ())
      ,@(if group-by (cons " GROUP BY " (sql-expand-list group-by)) ())
      ,@(if having (cons " HAVING " (sql-expand (car having))) ())
      ")")))

(def-sql-op :limit (form from &optional to)
  `("(" ,@(sql-expand form) " LIMIT " ,@(sql-expand from) ,@(if to (cons ", " (sql-expand to)) ()) ")"))

(def-sql-op :order-by (form &rest fields)
  `("(" ,@(sql-expand form) " ORDER BY " ,@(sql-expand-list fields) ")"))

(defun escape-sql-expression (expr)
  "Try to escape an expression at compile-time, if not possible, delay
to runtime. Used to create stored procedures."
  (let ((expanded (append (sql-expand expr) '(";"))))
    (if (every 'stringp expanded)
        (sql-escape-string (apply 'concatenate 'string expanded))
        `(sql-escape-string (concatenate 'string ,@(reduce-strings expanded))))))

(def-sql-op :function (name (&rest args) return-type stability body)
  (assert (member stability '(:immutable :stable :volatile)))
  `("CREATE OR REPLACE FUNCTION " ,@(sql-expand name) " (" ,(implode ", " (mapcar 'to-type-name args))
    ") RETURNS " ,(to-type-name return-type) " LANGUAGE SQL " ,(symbol-name stability) " AS " ,(escape-sql-expression body)))

(def-sql-op :insert-into (table insert-method &rest rest)
  (cond ((eq insert-method :set)
         (if (oddp (length rest))
             (error "Invalid amount of :set arguments passed to insert-into sql operator")
             `("INSERT INTO " ,@(sql-expand table) " (" 
               ,@(sql-expand-list (loop :for (field value) :on rest :by #'cddr
                                        :collect field)) ") VALUES ("
               ,@(sql-expand-list (loop :for (field value) :on rest :by #'cddr
                                        :collect value)) ")")))
        ((and (not rest) (consp insert-method) (eq (first insert-method) :select))
         `("INSERT INTO " ,@(sql-expand table) " " ,@(sql-expand insert-method)))
        (t
         (error "No :set arguments or select operator passed to insert-into sql operator"))))

(def-sql-op :update (table &rest args)
  (split-on-keywords ((set *) (where ?)) args
    (when (oddp (length set))
      (error "Invalid amount of :set arguments passed to update sql operator"))
    `("UPDATE " ,@(sql-expand table) " SET "
      ,@(loop :for (field value) :on set :by #'cddr
              :for first = t :then nil
              :append `(,@(if first () '(", ")) ,@(sql-expand field) " = " ,@(sql-expand value)))
      ,@(if where (cons " WHERE " (sql-expand (car where))) ()))))

(def-sql-op :delete-from (table &key where)
  `("DELETE FROM " ,@(sql-expand table) ,@(if where (cons " WHERE " (sql-expand where)) ())))

(def-sql-op :create-table (name &rest args)
  (flet ((dissect-type (type)
           (if (and (consp type) (eq (car type) 'or) (member 'db-null type) (= (length type) 3))
               (if (eq (second type) 'db-null)
                   (list (third type) t)
                   (list (second type) t))
               (list type nil))))
    (split-on-keywords ((fields *) (primary-key * ?)) (cons :fields args)
      `("CREATE TABLE " ,@(sql-expand name) " ("
        ,@(loop :for ((name type) . rest) :on fields
                :for (type-name type-null) = (dissect-type type)
                :append (sql-expand name)
                :collect " "
                :collect (to-type-name type-name)
                :if (not type-null)
                :collect " NOT NULL"
                :if rest
                :collect ", ")
        ,@(when primary-key `(", PRIMARY KEY(" ,@(sql-expand-list primary-key) ")"))
        ")"))))

(def-sql-op :drop-table (name)
  `("DROP TABLE " ,@(sql-expand name)))

(defun expand-create-index (name args)
  (split-on-keywords ((on) (using ?) (fields *)) args
    `(,@(sql-expand name) " ON " ,@(sql-expand (first on))
      ,@(when using `(" USING " ,(symbol-name (first using))))
      " (" ,@(sql-expand-list fields) ")")))

(def-sql-op :create-index (name &rest args)
  (cons "CREATE INDEX " (expand-create-index name args)))

(def-sql-op :create-unique-index (name &rest args)
  (cons "CREATE UNIQUE INDEX " (expand-create-index name args)))

(def-sql-op :drop-index (name)
  `("DROP INDEX " ,@(sql-expand name)))

(def-sql-op :create-sequence (name &key increment min-value max-value start cache cycle)
  `("CREATE SEQUENCE " ,@(sql-expand name) ,@(when increment `(" INCREMENT " ,@(sql-expand increment)))
    ,@(when min-value `(" MINVALUE " ,@(sql-expand min-value)))
    ,@(when max-value `(" MAXVALUE " ,@(sql-expand max-value)))
    ,@(when start `(" START " ,@(sql-expand start)))
    ,@(when cache `(" CACHE " ,@(sql-expand cache)))
    ,@(when cycle `(" CYCLE"))))

(def-sql-op :drop-sequence (name)
  `("DROP SEQUENCE " ,@(sql-expand name)))

;;; Copyright (c) 2006 Marijn Haverbeke & Streamtech
;;;
;;; This software is provided 'as-is', without any express or implied
;;; warranty. In no event will the authors be held liable for any
;;; damages arising from the use of this software.
;;;
;;; Permission is granted to anyone to use this software for any
;;; purpose, including commercial applications, and to alter it and
;;; redistribute it freely, subject to the following restrictions:
;;;
;;; 1. The origin of this software must not be misrepresented; you must
;;;    not claim that you wrote the original software. If you use this
;;;    software in a product, an acknowledgment in the product
;;;    documentation would be appreciated but is not required.
;;;
;;; 2. Altered source versions must be plainly marked as such, and must
;;;    not be misrepresented as being the original software.
;;;
;;; 3. This notice may not be removed or altered from any source
;;;    distribution.
