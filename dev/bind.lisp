;;;-*- Mode: Lisp; Package: bind -*-

#| simple-header

See the file COPYING for details

|#

(in-package #:metabang.bind) 

(defconstant +code-marker+ :XXX)
(defconstant +decl-marker+ :YYY)
    
(defgeneric binding-form-accepts-multiple-forms-p (binding-form)
  (:documentation "Returns true if a binding form can accept multiple forms
(e.g., :flet)"))

(defmethod binding-form-accepts-multiple-forms-p ((binding-form t))
  nil)

(defparameter *unused-declarations-behavior*
  :print-warning
  "Tells bind how to behave when it encounters an unused declaration.

The possible options are

* :print-warning (the current default) - print a warning about the problem 
   and signal a `bind-unused-declarations-condition`

* :warn - signal a `bind-unused-declarations-warning` warning

* :error - signal a `bind-unused-declarations-error` error")

(defparameter *bind-all-declarations*
  '(dynamic-extent ignore optimize ftype inline 
    special ignorable notinline type))

(defparameter *bind-non-var-declarations*
  '(optimize ftype inline notinline 
    #+allegro
    :explain))

(defparameter *bind-simple-var-declarations*
  (remove 'type
          (set-difference *bind-all-declarations* *bind-non-var-declarations*)))

(defparameter *bind-lambda-list-markers* 
  '(&key &body &rest &args &optional))

(define-condition simple-style-warning (style-warning simple-warning)
  ())

(defun simple-style-warning (message &rest args)
  (warn 'simple-style-warning :format-control message :format-arguments args))

(define-condition bind-missing-value-form-warning (simple-style-warning)
  ((variable-form :initform nil
		  :initarg :variable-form
		  :reader variable-form))
  (:report (lambda (c s)
	     (format s "Missing value form for ~s" (variable-form c)))))

(define-condition bind-too-many-value-forms-error (error)
  ((variable-form :initform nil
		  :initarg :variable-form
		  :reader variable-form)
   (value-form :initform nil
		  :initarg :value-form
		  :reader value-form))
  (:report (lambda (c s)
	     (format s "Two many value forms for ~s" (variable-form c)))))

(define-condition bind-error (error)
                  ((binding
		    :initform nil
		    :initarg :binding
		    :reader binding)))

(define-condition bind-keyword/optional-nil-with-default-error (bind-error)
                  ((bad-variable 
		    :initform nil
		    :initarg :bad-variable
		    :reader bad-variable))
  (:report (lambda (c s)
             (format s "Bad binding '~S' in '~A'; cannot use a default value for &key or &optional arguments."
                     (bad-variable c) (binding c)))))

(define-condition bind-unused-declarations-condition ()
  ((unused-declarations :initform (error "must supply unused-declarations")
			:initarg :unused-declarations
			:reader unused-declarations))
  (:report (lambda (c s)
	     (format s "Unused declarations in bind: ~{~s~^, ~}" (unused-declarations c)))))

(define-condition bind-unused-declarations-warning (bind-unused-declarations-condition
						   simple-style-warning)
  ())

(define-condition bind-unused-declarations-error (bind-unused-declarations-condition
						  error)
  ())

(defun binding-forms ()
  "Return a list of all binding-forms that bind supports in alphabetical order."
  (let* ((forms (get 'bind :binding-forms)))
    (sort (loop for form in forms collect (car form)) 'string-lessp)))

(defun binding-form-groups ()
  "Return a list of the available binding-forms grouped into their synonyms."
  (let ((binding-forms (get 'bind :binding-forms))
	(canonical-names
	 (sort
	  (delete-duplicates 
	   (mapcar #'second (get 'bind :binding-forms)))
	  #'string-lessp)))
    (loop for form in canonical-names collect
	 (cdr (assoc form binding-forms)))))

(defun binding-form-synonyms (name)
  "Return a list of synonyms for the binding-form `name`. 

For example

    > (binding-form-synonyms :accessors)
    (:accessors :writable-accessors)

"
  (let* ((forms (get 'bind :binding-forms))
	 (datum (assoc name forms)))
    (and datum
	 (rest datum))))

(defvar *all-declarations*)

(defmacro bind ((&rest bindings) &body body)
  "Bind is a replacement for let*, destructuring-bind, multiple-value-bind and more. 

An example is probably the best way to describe its syntax:

    \(bind \(\(a 2\)
           \(\(b &rest args &key \(c 2\) &allow-other-keys\) '\(:a :c 5 :d 10 :e 54\)\)
           \(\(:values d e\) \(truncate 4.5\)\)
           \(\(:structure xxx- slot1 slot2\) \(make-xxx\)\)
           \(\(:flet name \(arg1 arg2\)\) \(+ arg1 arg2\)\)\)
         \(list a b c d e args\)\)

Simple bindings are as in let*. Destructuring is done if the first item
in a binding is a list. Multiple value binding is done if the first item
in a binding is a list and the first item in the list is ':values'. Other
forms have their own syntax. For example, :structure first has the conc
name and then slot names whereas :flet has the function name and a list
of arguments and then the function body (in an implicit progn)."
  (let (declarations)
    (loop while (and (consp (car body)) (eq (caar body) 'declare)) do
          (push (first body) declarations)
          (setf body (rest body)))
    (if bindings
	(let ((*all-declarations* (bind-expand-declarations (nreverse declarations))))
	  (prog1
	      (bind-macro-helper bindings body)
	    (check-for-unused-variable-declarations *all-declarations*)))
        `(locally
             ,@declarations
           ,@body))))

(defun check-for-unused-variable-declarations (declarations)
  (when declarations
    (case *unused-declarations-behavior* 
      (:warn
       (warn 'bind-unused-declarations-warning :unused-declarations declarations))
      (:error
       (error 'bind-unused-declarations-error :unused-declarations declarations))
      (t
       (format *error-output* "~&;;; warning: unused declarations found in form: ~{~s~^, ~}."
	       declarations)
       (signal 'bind-unused-declarations-condition :unused-declarations declarations)))))

(defun bind-macro-helper (bindings body)
  (if bindings
      (let ((binding (first bindings))
	    (remaining-bindings (rest bindings))
	    variable-form value-form atomp binding-form)
	(if (consp binding)
	    (setf variable-form (first binding)
		  value-form (rest binding) ;; (second binding)
		  atomp (if (consp variable-form) nil (null value-form)))
	    (setf variable-form binding
		  atomp t))
	(unless (or atomp value-form)
	  (warn 'bind-missing-value-form-warning :variable-form variable-form))
	(setf binding-form (and (consp variable-form)
				(and (symbolp (first variable-form))
				     (eq (symbol-package (first variable-form))
					 (load-time-value (find-package :keyword)))
				     (first variable-form))))
	(when (and (consp value-form) 
		   (cdr value-form)
		   (if (null binding-form)
                       (not (binding-form-accepts-multiple-forms-p variable-form))
		       (not (binding-form-accepts-multiple-forms-p binding-form))))
	  (error 'bind-too-many-value-forms-error 
		:variable-form variable-form :value-form value-form))
	(let* ((body (bind-macro-helper remaining-bindings body))
	       (variables (if binding-form (rest variable-form) variable-form))
	       (decls (bind-filter-declarations variables)))
	  (multiple-value-bind (form double-indent)
	      (if binding-form
		  ;; e.g., (:values ...)
		  (bind-generate-bindings (first variable-form) (rest variable-form) value-form)
		  ;; e.g., #(a b c)
		  (bind-generate-bindings variable-form variable-form value-form))
	    (cond ((or (tree-find form +code-marker+)
		       (tree-find form +decl-marker+))
		   (setf form (subst body +code-marker+ form))
		   (setf form (subst decls +decl-marker+ form)))
		  (double-indent
		   `(,@(butlast form) (,@(first (last form)) ,@decls ,body)))
		  ((merge-binding-forms-p form body)
		   (destructuring-bind (head1 form1-bindings . form1-code)
		       form
		     (destructuring-bind (_ form2-bindings . form2-code)
			 body
		       (declare (ignore _))
		       `(,head1 (,@form1-bindings ,@form2-bindings)
				,@decls 
				,@form1-code
				,@form2-code))))
		  (t
		   `(,@form ,@decls ,body))))))
      `(progn ,@body)))

;;;;

(defun var-ignorable-p (var)
  (or (null var) 
      (and (symbolp var) (string= (symbol-name var) (symbol-name '_)))))

(defun mint-ignorable-variable ()
  (gensym (symbol-name '#:bind-ignore-)))

(defun bind-fix-nils (var-list)
  (let (vars ignores)
    (loop for v in var-list do
          (cond ((var-ignorable-p v)
		 (let ((ignore (mint-ignorable-variable)))
                     (push ignore vars)
                     (push ignore ignores)))
		(t (push v vars))))
    (values (nreverse vars) ignores)))

(defun bind-fix-nils-destructured (var-list)
  (let ((ignores nil))
    (flet ((maybe-handle-1 (x)
	     (if (var-ignorable-p x)
		 (let ((ignore (mint-ignorable-variable)))
		   (push ignore ignores)
		   ignore)
		 x)))
    (labels ((do-it (it key?)
	       (cond ((null it)
		      nil)
		     ((atom it)
		      (maybe-handle-1 it))
		     ((dotted-pair-p it)
		      (cons (do-it (car it) key?) (do-it (cdr it) key?)))
		     ((eq (first it) '&key)
		      (loop for x in it collect (do-it x t)))
		     (key?
		      it)
		     (t
		      (cons (do-it (car it) key?)
			    (do-it (cdr it) key?))))))
      (values (do-it var-list nil) ignores)))))

(defun dotted-pair-p (putative-pair)
  "Returns true if and only if `putative-pair` is a dotted-list. I.e., if `putative-pair` is a cons cell with a non-nil cdr."
  (and (consp putative-pair)
       (cdr putative-pair)
       (not (consp (cdr putative-pair)))))

(defmethod bind-collect-variables (kind variable-form)
  (declare (ignore kind))
  variable-form)

(defun bind-get-vars-from-lambda-list (lambda-list)
  (let ((result nil))
    (labels ((do-it (thing)
	       (cond ((arrayp thing)
		      (loop for i below (array-total-size thing)
			 for var = (row-major-aref thing i) do (do-it var)))
		     ((atom thing) 
		      (unless (or (member thing *bind-lambda-list-markers*)
				  (var-ignorable-p thing))
			(push thing result)))
		     ((dotted-pair-p thing)
		      (do-it (car thing)) 
		      (do-it (cdr thing)))
		     (t
		      (do-it (car thing))
		      (do-it (cdr thing))))))
      (do-it lambda-list))
    (nreverse result)))

(defun bind-expand-declarations (declarations)
  (loop for declaration in declarations append
        (loop for decl in (rest declaration) append
              (cond ((member (first decl) *bind-non-var-declarations*)
                     (list decl))
                    ((member (first decl) *bind-simple-var-declarations*)
                     (loop for var in (rest decl) collect
                           `(,(first decl) ,var)))
                    (t
                     ;; a type spec
                     (when (eq (first decl) 'type)
                       (setf decl (rest decl)))
                     (loop for var in (rest decl) collect
                           `(type ,(first decl) ,var)))))))

(defun bind-filter-declarations (var-names)
  (setf var-names (if (consp var-names) var-names (list var-names)))  
  (setf var-names (bind-get-vars-from-lambda-list var-names))
  ;; each declaration is separate
  (let ((declaration
         (loop for declaration in *all-declarations*
               when (or (member (first declaration)
				*bind-non-var-declarations*)
                        (and (member (first declaration)
				     *bind-simple-var-declarations*)
			     (member 
			      (if (atom (second declaration))
				  (second declaration)
				  ;; ... (function foo) ...)
			   	  (second (second declaration)))
			      var-names))
			;; type
                        (member (third declaration) var-names)) collect
	      (progn
		(setf *all-declarations* (remove declaration *all-declarations*))
		declaration))))
    (when declaration 
      `((declare ,@declaration)))))

(defun merge-binding-forms-p (form1 form2)
  (and (consp form1) (consp form2)
       (let ((tag1 (first form1))
	     (tag2 (first form2)))
	 (and (symbolp tag1)
	      (symbolp tag2)
	      (string-equal (symbol-name tag1) (symbol-name tag2))
	      (or (string-equal (symbol-name tag1) "let")
		  (string-equal (symbol-name tag1) "let*")
		  (string-equal (symbol-name tag1) "labels"))))))

(defun map-tree (fn object)
  "apply `fn` to every leaf of `object`."
  (cond ((consp object)
         (map-tree fn (car object))
         (map-tree fn (cdr object)))
        (object
         (funcall fn object))))

(defun tree-find (tree it &key (test #'eq) (key #'identity))
  (flet ((isit (atom)
           (when key (setf atom (funcall key atom)))
           (when (funcall test it atom) (return-from tree-find t))))
    (declare (dynamic-extent #'isit))
    (map-tree #'isit tree)))

;;; fluid-bind

(defmacro fluid-bind ((&rest bindings) &body body)
  "Fluid-bind is an extension of bind that handles setting and resetting places. For example, suppose that an object of class foo has a slot named bar whose value is currently 3. The following code would evaluate the inner body with bar bound to 17 and restore it when the inner body is exited. 

\(fluid-bind \(\(\(bar foo\) 17\)\)
  \(print \(bar foo\)\)\)
\(print \(bar foo\)\)
==> \(prints 17, then 3\)

This is similar to dynamic-binding but _much_ less robust."
  ;; does not handle declarations correctly
  (let ((setup-forms nil)
        (cleanup-forms nil)
        (gensyms nil))
    (loop for binding in bindings collect
          (destructuring-bind 
		(setup-form cleanup-form)
	      (cond ((consp binding)
		     (destructuring-bind (var value) binding
		       (let ((g (gensym)))
			 (push g gensyms)
			 (cond ((atom var)
				`((:bind (,var ,value)) nil)
				#+(or)
				;; lexical or special?
				(if (boundp var)
				    `((:bind (,var ,value)) nil)
				    `((:setf (setf ,g ,var ,var ,value))
				      (setf ,var ,g))))
			       ((and (fboundp (first var))
				     (not (eq (first var) 'values)))
				;; putative place
				`((:setf (setf ,g ,var ,var ,value))
				  (setf ,var ,g)))
			       (t
				`((:bind (,var ,value)) nil))))))
		    (t
		     `((:bind (,binding nil)) nil)))
            (push setup-form setup-forms)
            (push cleanup-form cleanup-forms)))
    (let ((result body))
      (mapc (lambda (setup cleanup)
              (setf result
                    (ecase (first setup)
                      (:setf `((unwind-protect
                                 (progn
                                   ,(second setup)
                                   ,@result)
                                 ,cleanup)))
                      (:bind `((bind (,(second setup))
                                 ,@result)))))
              result)
            setup-forms cleanup-forms)
      `(let ,gensyms
         (declare (ignorable ,@gensyms))
         ,@result))))

#|
(let ((a 2))
  (fluid-bind ((a 3))
    (print a))
  (print a))

(fluid-bind (((population (current-world-state)) t))
  (print (population (current-world-state))))

(fluid-bind ((a 3)
             (*last-world* t)
             (*foo* nil))
  (declare (fixnum a))
  (print (list *last-world* *foo* a))
  (error "Ouch"))

(defvar *foo* 3)

(unwind-protect
  (bind ((#:g1 *last-world*))
    (setf *last-world* t)
    (unwind-protect
      (bind ((#:2 *foo*))
        (setf *foo* nil)
        (bind ((a 3))
          (list *last-world* *foo* a)))
      (setf *foo #:2)))
  (set *last-world* #:g1))      
    
(fluid-bind (a b)
  (+ a a))
|#


