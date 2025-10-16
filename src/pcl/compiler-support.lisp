;;;; things which the main SBCL compiler needs to know about the
;;;; implementation of CLOS
;;;;
;;;; (Our CLOS is derived from PCL, which was implemented in terms of
;;;; portable high-level Common Lisp. But now that it no longer needs
;;;; to be portable, we can make some special hacks to support it
;;;; better.)

;;;; This software is part of the SBCL system. See the README file for more
;;;; information.

;;;; This software is derived from software originally released by Xerox
;;;; Corporation. Copyright and release statements follow. Later modifications
;;;; to the software are in the public domain and are provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for more
;;;; information.

;;;; copyright information from original PCL sources:
;;;;
;;;; Copyright (c) 1985, 1986, 1987, 1988, 1989, 1990 Xerox Corporation.
;;;; All rights reserved.
;;;;
;;;; Use and copying of this software and preparation of derivative works based
;;;; upon this software are permitted. Any distribution of this software or
;;;; derivative works must comply with all applicable United States export
;;;; control laws.
;;;;
;;;; This software is made available AS IS, and Xerox Corporation makes no
;;;; warranty about the software, its performance or its conformity to any
;;;; specification.

(in-package "SB-C")

;;;; very low-level representation of instances with meta-class
;;;; STANDARD-CLASS

(deftransform sb-pcl::pcl-instance-p ((object))
  ;; We declare SPECIFIER-TYPE notinline here because otherwise the
  ;; literal classoid reflection/dumping machinery will instantiate
  ;; the type at Genesis time, confusing PCL bootstrapping.
  (declare (notinline specifier-type))
  (let* ((otype (lvar-type object))
         (standard-object (specifier-type 'standard-object)))
    ;; Flush tests whose result is known at compile time.
    (cond ((csubtypep otype standard-object) t)
          ((not (types-equal-or-intersect otype standard-object)) nil)
          (t `(%pcl-instance-p object)))))

(define-load-time-global sb-pcl::*internal-pcl-generalized-fun-name-symbols* nil)

(defmacro define-internal-pcl-function-name-syntax (name (var) &body body)
  `(progn
     (define-function-name-syntax ,name (,var) ,@body)
     (pushnew ',name sb-pcl::*internal-pcl-generalized-fun-name-symbols*)))

(define-internal-pcl-function-name-syntax sb-pcl::slot-accessor (list)
  (when (= (length list) 4)
    (destructuring-bind (class slot rwb) (cdr list)
      (when (and (member rwb '(sb-pcl::reader sb-pcl::writer
                               sb-pcl::boundp sb-pcl::makunbound))
                 (symbolp slot)
                 (symbolp class))
        (values t slot)))))

(define-internal-pcl-function-name-syntax sb-pcl::fast-method (list)
  (valid-function-name-p (cadr list)))

(define-internal-pcl-function-name-syntax sb-pcl::slow-method (list)
  (valid-function-name-p (cadr list)))

(flet ((union-of-known-slot-p (slot-name objtype)
         ;; handle an either-or of two structure classoids
         ;; (This could accept N types in the union but it's tricky)
         (binding* ((c1 (car (union-type-types objtype)))
                    (c2 (cadr (union-type-types objtype)))
                    (dd1 (find-defstruct-description (classoid-name c1)))
                    (dd2 (find-defstruct-description (classoid-name c2)))
                    (dsd1 (find slot-name (dd-slots dd1) :key #'dsd-name))
                    (dsd2 (find slot-name (dd-slots dd2) :key #'dsd-name))
                    ;; If one type is frozen, prefer TYPEP on it as the discriminator
                    ;; since the test is quicker than a hierarchical test.
                    ((discriminator then else)
                     (cond ((or (not dsd1) (not dsd2))
                            (return-from union-of-known-slot-p nil))
                           ((and (eq (classoid-state c2) :sealed)
                                 (neq (classoid-state c1) :sealed))
                            (values c2 dsd2 dsd1))
                           (t
                            (values c1 dsd1 dsd2))))
                    (test `(typep object ',(classoid-name discriminator))))
           (if (and (eq (dsd-raw-type dsd1) (dsd-raw-type dsd2))
                    (type= (specifier-type (dsd-type dsd1))
                           (specifier-type (dsd-type dsd2)))
                    ;; If the slots don't have the same dsd-index, there would be an IF
                    ;; as the argument to %instance-ref which is actually worse (it seems)
                    ;; than putting the IF around the two accessors. That's too bad,
                    ;; because I thought it was clever to put the IF inside. It's possible
                    ;; to improve asm codegen to handle it- a layout comparison which sets
                    ;; flags, and a CMOV, essentially reading both slots but choosing one
                    ;; result. Both structs need to be sufficiently long to avoid overrun.
                    (= (dsd-index dsd1) (dsd-index dsd2)))
               ;; Two _unrelated_ structures with essentially the same slot.
               ;; (If one was an ancestor of the other, this would not be a UNION type)
               (let ((i (if (= (dsd-index dsd1) (dsd-index dsd2)) ; ALWAYS TRUE (for now)
                            (dsd-index dsd1) ; same word of the structure
                            `(if ,test ,(dsd-index then) ,(dsd-index else)))))
                 ;; I blindly copied this expansion from that of a typical DEFSTRUCT's
                 ;; accessor. I don't claim to understand the use of THE*.
                 `(the* (,(dsd-type dsd1) :derive-type-only t)
                        (,(dsd-reader dsd1 nil) object ,i)))
               ;; slots differ in physical representation and/or lisp type
               `(if ,test
                    (,(dsd-accessor-name then) object)
                    (,(dsd-accessor-name else) object)))))
       (always-bound-struct-accessor-p (object slot-name &optional nullable)
         ;; If NULLABLE is true then the caller can deal with the possibility
         ;; of object being either NIL or a structure instance.
         (let ((c-slot-name (lvar-value slot-name)))
           (unless (interned-symbol-p c-slot-name)
             (give-up-ir1-transform "slot name is not an interned symbol"))
           (let* ((unmodified-type (lvar-type object))
                  (type (if (and nullable
                                 (union-type-p unmodified-type)
                                 (member (specifier-type 'null)
                                         (union-type-types unmodified-type)))
                            (type-difference unmodified-type (specifier-type 'null))
                            unmodified-type))
                  (dd (when (structure-classoid-p type)
                        (find-defstruct-description (classoid-name type))))
                  (dsd (when dd
                         (find c-slot-name (dd-slots dd) :key #'dsd-name))))
             (when (and dsd (dsd-always-boundp dsd))
               dsd)))))

  (deftransform slot-boundp ((object slot-name) (t (constant-arg symbol)) *
                             :node node)
    (cond ((always-bound-struct-accessor-p object slot-name) t)
          (t (delay-ir1-transform node :constraint)
             `(sb-pcl::%accessor-slot-boundp object ',(lvar-value slot-name)))))

  (deftransform slot-makunbound ((object slot-name) (t (constant-arg symbol)) *
                                 :node node)
    (cond ((always-bound-struct-accessor-p object slot-name)
           `(error "Cannot make slot ~S in ~S unbound." ',object ',slot-name))
          (t (delay-ir1-transform node :constraint)
             `(sb-pcl::%accessor-slot-makunbound object ',(lvar-value slot-name)))))

  ;; this transform is tried LAST because we like to make things unintuitive
  (deftransform slot-value ((object slot-name) (structure-object symbol) *
                            ;; safety 3 should check slot-unbound on structures
                            :policy (< safety 3))
    (cond ((and (constant-lvar-p slot-name)
                (let ((objtype (lvar-type object)))
                  (and (union-type-p objtype)
                       (not (cddr (union-type-types objtype))) ; 2-way choice
                       (union-of-known-slot-p (lvar-value slot-name) objtype)))))
          (t
           `(sb-pcl::structure-slot-value object slot-name))))

  (deftransform slot-value ((object slot-name) (t (constant-arg symbol)) *
                            :node node)
    (acond ((always-bound-struct-accessor-p object slot-name)
            `(,(dsd-accessor-name it) object))
           ((always-bound-struct-accessor-p object slot-name t)
            ;; CLHS says in SLOT-VALUE "An error is always signaled if object
            ;; has metaclass built-in-class." which means that regardless
            ;; of compilation policy, we need to signal an error on NIL.
            `(if object
                 (,(dsd-accessor-name it) object)
                 (sb-pcl::nil-not-slot-object ',(lvar-value slot-name))))
           (t
            (delay-ir1-transform node :constraint)
            `(sb-pcl::%accessor-slot-value object ',(lvar-value slot-name)))))

  (deftransform sb-pcl::set-slot-value ((object slot-name new-value)
                                        (t (constant-arg symbol) t)
                                        * :node node)
    (acond ((always-bound-struct-accessor-p object slot-name)
            `(setf (,(dsd-accessor-name it) object) new-value))
           ((policy node (= safety 3))
            ;; Safe code wants to check the type, and the global
            ;; accessor won't do that.
            (give-up-ir1-transform "cannot use optimized accessor in safe code"))
           (t
            (delay-ir1-transform node :constraint)
            `(sb-pcl::%accessor-set-slot-value object ',(lvar-value slot-name)
                                               new-value)))))
