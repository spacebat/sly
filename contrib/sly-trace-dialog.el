;;; -*- coding: utf-8; lexical-binding: t -*-
;;;
;;; sly-trace-dialog.el -- a navigable dialog of inspectable trace entries
;;;
;;; TODO: implement better wrap interface for sbcl method, labels and such
;;; TODO: backtrace printing is very slow
;;;
(require 'sly)
(require 'sly-parse)
(require 'cl-lib)

(define-sly-contrib sly-trace-dialog
  "Provide an interfactive trace dialog buffer for managing and
inspecting details of traced functions. Invoke this dialog with C-c T."
  (:authors "João Távora <joaotavora@gmail.com>")
  (:license "GPL")
  (:swank-dependencies swank-trace-dialog)
  (:on-load (add-hook 'sly-mode-hook 'sly-trace-dialog-enable))
  (:on-unload (remove-hook 'sly-mode-hook 'sly-trace-dialog-enable)))


;;;; Variables
;;;
(defvar sly-trace-dialog-flash t
  "Non-nil means flash the updated region of the SLY Trace Dialog. ")

(defvar sly-trace-dialog--specs-overlay nil)

(defvar sly-trace-dialog--progress-overlay nil)

(defvar sly-trace-dialog--tree-overlay nil)

(defvar sly-trace-dialog--collapse-chars (cons "-" "+"))


;;;; Local trace entry model
(defvar sly-trace-dialog--traces nil)

(cl-defstruct (sly-trace-dialog--trace
               (:constructor sly-trace-dialog--make-trace))
  id
  parent
  spec
  args
  retlist
  depth
  beg
  end
  collapse-button-marker
  summary-beg
  children-end
  collapsed-p)

(defun sly-trace-dialog--find-trace (id)
  (gethash id sly-trace-dialog--traces))


;;;; Modes and mode maps
;;;
(defvar sly-trace-dialog-mode-map
  (let ((map (make-sparse-keymap))
        (remaps '((sly-inspector-operate-on-point . nil)
                  (sly-inspector-operate-on-click . nil)
                  (sly-inspector-reinspect
                   . sly-trace-dialog-fetch-status)
                  (sly-inspector-next-inspectable-object
                   . sly-trace-dialog-next-button)
                  (sly-inspector-previous-inspectable-object
                   . sly-trace-dialog-prev-button))))
    (set-keymap-parent map sly-inspector-mode-map)
    (cl-loop for (old . new) in remaps
             do (substitute-key-definition old new map))
    (set-keymap-parent map sly-parent-map)
    (define-key map (kbd "G") 'sly-trace-dialog-fetch-traces)
    (define-key map (kbd "C-k") 'sly-trace-dialog-clear-fetched-traces)
    (define-key map (kbd "g") 'sly-trace-dialog-fetch-status)
    (define-key map (kbd "q") 'quit-window)
    map))

(define-derived-mode sly-trace-dialog-mode fundamental-mode
  "SLY Trace Dialog" "Mode for controlling SLY's Trace Dialog"
  (set-syntax-table lisp-mode-syntax-table)
  (read-only-mode 1)
  (add-to-list (make-local-variable 'sly-trace-dialog-after-toggle-hook)
               'sly-trace-dialog-fetch-status))

(define-derived-mode sly-trace-dialog--detail-mode sly-inspector-mode
  "SLY Trace Detail"
  "Mode for viewing a particular trace from SLY's Trace Dialog")

(setq sly-trace-dialog--detail-mode-map
      (let ((map (make-sparse-keymap))
            (remaps '((sly-inspector-next-inspectable-object
                       . sly-trace-dialog-next-button)
                      (sly-inspector-previous-inspectable-object
                       . sly-trace-dialog-prev-button))))
        (set-keymap-parent map sly-trace-dialog-mode-map)
        (cl-loop for (old . new) in remaps
                 do (substitute-key-definition old new map))
        map))

(defvar sly-trace-dialog-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c T") 'sly-trace-dialog)
    (define-key map (kbd "C-c M-t") 'sly-trace-dialog-toggle-trace)
    map))

(define-minor-mode sly-trace-dialog-minor-mode
  "Add keybindings for accessing SLY's Trace Dialog.")

(defun sly-trace-dialog-enable ()
  (sly-trace-dialog-minor-mode 1))

(easy-menu-define sly-trace-dialog--menubar (list sly-trace-dialog-minor-mode-map
                                                    sly-trace-dialog-mode-map)
  "A menu for accessing some features of SLY's Trace Dialog"
  (let* ((in-dialog '(eq major-mode 'sly-trace-dialog-mode))
         (dialog-live `(and ,in-dialog
                            (memq sly-buffer-connection sly-net-processes)))
         (connected '(sly-connected-p)))
    `("Trace"
      ["Toggle trace" sly-trace-dialog-toggle-trace ,connected]
      ["Trace complex spec" sly-trace-dialog-toggle-complex-trace ,connected]
      ["Open Trace dialog" sly-trace-dialog (and ,connected (not ,in-dialog))]
      "--"
      [ "Refresh traces and progress" sly-trace-dialog-fetch-status ,dialog-live]
      [ "Fetch next batch" sly-trace-dialog-fetch-traces ,dialog-live]
      [ "Clear all fetched traces" sly-trace-dialog-clear-fetched-traces ,dialog-live]
      [ "Toggle details" sly-trace-dialog-hide-details-mode ,in-dialog]
      [ "Toggle autofollow" sly-trace-dialog-autofollow-mode ,in-dialog])))

(define-minor-mode sly-trace-dialog-hide-details-mode
  "Hide details in `sly-trace-dialog-mode'"
  nil " Brief"    
  :group 'sly-trace-dialog
  (unless (derived-mode-p 'sly-trace-dialog-mode)
    (error "Not a SLY Trace Dialog buffer"))
  (sly-trace-dialog--set-hide-details-mode))

(define-minor-mode sly-trace-dialog-autofollow-mode
  "Automatically open buffers with trace details from `sly-trace-dialog-mode'"
  nil " Autofollow"
  :group 'sly-trace-dialog
  (unless (derived-mode-p 'sly-trace-dialog-mode)
    (error "Not a SLY Trace Dialog buffer")))


;;;; Helper functions
;;;
(defun sly-trace-dialog--call-refreshing (buffer
                                            overlay
                                            dont-erase
                                            recover-point-p
                                            fn)
  (with-current-buffer buffer
    (let ((inhibit-point-motion-hooks t)
          (inhibit-read-only t)
          (saved (point)))
      (save-restriction
        (when overlay
          (narrow-to-region (overlay-start overlay)
                            (overlay-end overlay)))
        (unwind-protect
            (if dont-erase
                (goto-char (point-max))
              (delete-region (point-min) (point-max)))
          (funcall fn)
          (when recover-point-p
            (goto-char saved)))
        (when sly-trace-dialog-flash
          (sly-flash-region (point-min) (point-max)))))
    buffer))

(cl-defmacro sly-trace-dialog--refresh ((&key
                                           overlay
                                           dont-erase
                                           recover-point-p
                                           buffer)
                                          &rest body)
  (declare (indent 1)
           (debug (sexp &rest form)))
  `(sly-trace-dialog--call-refreshing ,(or buffer
                                             `(current-buffer))
                                        ,overlay
                                        ,dont-erase
                                        ,recover-point-p
                                        #'(lambda () ,@body)))

(defmacro sly-trace-dialog--insert-and-overlay (string overlay)
  `(save-restriction
     (let ((inhibit-read-only t))
       (narrow-to-region (point) (point))
       (insert ,string "\n")
       (set (make-local-variable ',overlay)
            (let ((overlay (make-overlay (point-min)
                                         (point-max)
                                         (current-buffer)
                                         nil
                                         t)))
              (move-overlay overlay (overlay-start overlay)
                            (1- (overlay-end overlay)))
              ;; (overlay-put overlay 'face '(:background "darkslategrey"))
              overlay)))))

(defun sly-trace-dialog--buffer-name ()
  (format "*traces for %s*"
          (sly-connection-name sly-default-connection)))

(defun sly-trace-dialog--live-dialog (&optional buffer-or-name)
  (let ((buffer-or-name (or buffer-or-name
                            (sly-trace-dialog--buffer-name))))
    (and (buffer-live-p (get-buffer buffer-or-name))
       (with-current-buffer buffer-or-name
         (memq sly-buffer-connection sly-net-processes))
       buffer-or-name)))

(defun sly-trace-dialog--ensure-buffer ()
  (let ((name (sly-trace-dialog--buffer-name)))
    (or (sly-trace-dialog--live-dialog name)
        (with-current-buffer (get-buffer-create name)
          (let ((inhibit-read-only t))
            (erase-buffer))
          (sly-trace-dialog-mode)
          (save-excursion
            (buffer-disable-undo)
            (sly-trace-dialog--insert-and-overlay
             "[waiting for the traced specs to be available]"
             sly-trace-dialog--specs-overlay)
            (sly-trace-dialog--insert-and-overlay
             "[waiting for some info on trace download progress ]"
             sly-trace-dialog--progress-overlay)
            (sly-trace-dialog--insert-and-overlay
             "[waiting for the actual traces to be available]"
             sly-trace-dialog--tree-overlay)
            (current-buffer))
          (setq sly-buffer-connection sly-default-connection)
          (current-buffer)))))

(defun sly-trace-dialog--make-autofollow-fn (id)
  (let ((requested nil))
    #'(lambda (_before after)
        (let ((inhibit-point-motion-hooks t)
              (id-after (get-text-property after 'sly-trace-dialog--id)))
          (when (and (= after (point))
                     sly-trace-dialog-autofollow-mode
                     id-after
                     (= id-after id)
                     (not requested))
            (setq requested t)
            (sly-eval-async `(swank-trace-dialog:report-trace-detail
                                ,id-after)
              #'(lambda (detail)
                  (setq requested nil)
                  (when detail
                    (let ((inhibit-point-motion-hooks t))
                      (sly-trace-dialog--open-detail detail
                                                       'no-pop))))))))))

(defun sly-trace-dialog--set-collapsed (collapsed-p trace button)
  (save-excursion
    (setf (sly-trace-dialog--trace-collapsed-p trace) collapsed-p)
    (sly-trace-dialog--go-replace-char-at
     button
     (if collapsed-p
         (cdr sly-trace-dialog--collapse-chars)
       (car sly-trace-dialog--collapse-chars)))
    (sly-trace-dialog--hide-unhide
     (sly-trace-dialog--trace-summary-beg trace)
     (sly-trace-dialog--trace-end trace)
     (if collapsed-p 1 -1))
    (sly-trace-dialog--hide-unhide
     (sly-trace-dialog--trace-end trace)
     (sly-trace-dialog--trace-children-end trace)
     (if collapsed-p 1 -1))))

(defun sly-trace-dialog--hide-unhide (start-pos end-pos delta)
  (cl-loop with inhibit-read-only = t
           for pos = start-pos then next
           for next = (next-single-property-change
                       pos
                       'sly-trace-dialog--hidden-level
                       nil
                       end-pos)
           for hidden-level = (+ (or (get-text-property
                                      pos
                                      'sly-trace-dialog--hidden-level)
                                     0)
                                 delta)
           do (add-text-properties pos next
                                   (list 'sly-trace-dialog--hidden-level
                                         hidden-level
                                         'invisible
                                         (cl-plusp hidden-level)))
           while (< next end-pos)))

(defun sly-trace-dialog--set-hide-details-mode ()
  (cl-loop for trace being the hash-values of sly-trace-dialog--traces
           do (sly-trace-dialog--hide-unhide
               (sly-trace-dialog--trace-summary-beg trace)
               (sly-trace-dialog--trace-end trace)
               (if sly-trace-dialog-hide-details-mode 1 -1))))

(defun sly-trace-dialog--format-part (part-id part-text trace-id type)
  (sly-trace-dialog--button
   (format "%s" part-text)
   #'(lambda (_button)
       (sly-eval-async
           `(swank-trace-dialog:inspect-trace-part ,trace-id ,part-id ,type)
         #'sly-open-inspector))
   'mouse-face 'highlight
   'sly-trace-dialog--part-id part-id
   'sly-trace-dialog--type type
   'face 'sly-inspectable-value-face))

(defun sly-trace-dialog--format-trace-entry (id external)
  (sly-trace-dialog--button
   (format "%s" external)
   #'(lambda (_button)
       (sly-eval-async
           `(swank::inspect-object (swank-trace-dialog::find-trace ,id))
         #'sly-open-inspector))
   'face 'sly-inspector-value-face))

(defun sly-trace-dialog--format (fmt-string &rest args)
  (let* ((string (apply #'format fmt-string args))
         (indent (make-string (max 2
                                   (- 50 (length string))) ? )))
    (format "%s%s" string indent)))

(defun sly-trace-dialog--button (title lambda &rest props)
  (let ((string (format "%s" title)))
    (apply #'make-text-button string nil
           'action     #'(lambda (button)
                           (funcall lambda button))
           'mouse-face 'highlight
           'face       'sly-inspector-action-face
           props)
    string))

(defun sly-trace-dialog--call-maintaining-properties (pos fn)
  (save-excursion
    (goto-char pos)
    (let* ((saved-props (text-properties-at pos))
           (saved-point (point))
           (inhibit-read-only t)
           (inhibit-point-motion-hooks t))
      (funcall fn)
      (add-text-properties saved-point (point) saved-props)
      (if (markerp pos) (set-marker pos saved-point)))))

(cl-defmacro sly-trace-dialog--maintaining-properties (pos
                                                         &body body)
  (declare (indent 1))
  `(sly-trace-dialog--call-maintaining-properties ,pos #'(lambda () ,@body)))

(defun sly-trace-dialog--go-replace-char-at (pos char)
  (sly-trace-dialog--maintaining-properties pos
    (delete-char 1)
    (insert char)))


;;;; Handlers for the *trace-dialog* and *trace-detail* buffers
;;;
(defun sly-trace-dialog--open-specs (traced-specs)
  (cl-labels ((make-report-spec-fn
               (&optional form)
               #'(lambda (_button)
                   (sly-eval-async
                       `(cl:progn
                         ,form
                         (swank-trace-dialog:report-specs))
                     #'(lambda (results)
                         (sly-trace-dialog--open-specs results))))))
    (sly-trace-dialog--refresh
        (:overlay sly-trace-dialog--specs-overlay
                  :recover-point-p t)
      (insert
       (sly-trace-dialog--format "Traced specs (%s)" (length traced-specs))
       (sly-trace-dialog--button "[refresh]"
                                   (make-report-spec-fn))
       "\n" (make-string 50 ? )
       (sly-trace-dialog--button
        "[untrace all]"
        (make-report-spec-fn `(swank-trace-dialog:dialog-untrace-all)))
       "\n\n")
      (cl-loop for spec in traced-specs
               do (insert
                   "  "
                   (sly-trace-dialog--button
                    "[untrace]"
                    (make-report-spec-fn
                     `(swank-trace-dialog:dialog-untrace ',spec)))
                   (format " %s" spec)
                   "\n")))))

(defvar sly-trace-dialog--fetch-key nil)

(defvar sly-trace-dialog--stop-fetching nil)

(defun sly-trace-dialog--update-progress (total &optional show-stop-p remaining-p)
  ;; `remaining-p' indicates `total' is the number of remaining traces.
  (sly-trace-dialog--refresh
      (:overlay sly-trace-dialog--progress-overlay
                :recover-point-p t)
    (let* ((done (hash-table-count sly-trace-dialog--traces))
           (total (if remaining-p (+ done total) total)))
      (insert
       (sly-trace-dialog--format "Trace collection status (%d/%s)"
                                   done
                                   (or total "0"))
       (sly-trace-dialog--button "[refresh]"
                                   #'(lambda (_button)
                                       (sly-trace-dialog-fetch-progress))))

      (when (and total (cl-plusp (- total done)))
        (insert "\n" (make-string 50 ? )
                (sly-trace-dialog--button
                 "[fetch next batch]"
                 #'(lambda (_button)
                     (sly-trace-dialog-fetch-traces nil)))
                "\n" (make-string 50 ? )
                (sly-trace-dialog--button
                 "[fetch all]"
                 #'(lambda (_button)
                     (sly-trace-dialog-fetch-traces t)))))
      (when total
        (insert "\n" (make-string 50 ? )
                (sly-trace-dialog--button
                 "[clear]"
                 #'(lambda (_button)
                     (sly-trace-dialog-clear-fetched-traces)))))
      (when show-stop-p
        (insert "\n" (make-string 50 ? )
                (sly-trace-dialog--button
                 "[stop]"
                 #'(lambda (_button)
                     (setq sly-trace-dialog--stop-fetching t)))))
      (insert "\n\n"))))

(defun sly-trace-dialog--open-detail (trace-tuple &optional no-pop)
  (sly-with-popup-buffer ("*trace-detail*" :select (not no-pop)
                            :mode 'sly-trace-dialog--detail-mode)
    (cl-destructuring-bind (id _parent-id _spec args retlist backtrace external)
        trace-tuple
      (let ((headline (sly-trace-dialog--format-trace-entry id external)))
        (setq headline (format "%s\n%s\n"
                               headline
                               (make-string (length headline) ?-)))
        (insert headline))
      (cl-loop for (type objects label)
               in `((:arg ,args   "Called with args:")
                    (:retval ,retlist "Returned values:"))
               do (insert (format "\n%s\n" label))
               (insert (cl-loop for object in objects
                                for i from 0
                                concat (format "   %s: %s\n" i
                                               (sly-trace-dialog--format-part
                                                (cl-first object)
                                                (cl-second object)
                                                id
                                                type)))))
      (when backtrace
        (insert "\nBacktrace:\n"
                (cl-loop for (i spec) in backtrace
                         concat (format "   %s: %s\n" i spec)))))))


;;;; Rendering traces
;;;
(defun sly-trace-dialog--draw-tree-lines (start offset direction)
  (save-excursion
    (let ((inhibit-point-motion-hooks t))
      (goto-char start)
      (cl-loop with replace-set = (if (eq direction 'down)
                                      '(? )
                                    '(?  ?`))
               for line-beginning = (line-beginning-position
                                     (if (eq direction 'down)
                                         2 0))
               for pos = (+ line-beginning offset)
               while (and (< (point-min) line-beginning)
                          (< line-beginning (point-max))
                          (memq (char-after pos) replace-set))
               do
               (sly-trace-dialog--go-replace-char-at pos "|")
               (goto-char pos)))))

(defun sly-trace-dialog--make-indent (depth suffix)
  (concat (make-string (* 3 (max 0 (1- depth))) ? )
          (if (cl-plusp depth) suffix)))

(defun sly-trace-dialog--make-collapse-button (trace)
  (sly-trace-dialog--button (if (sly-trace-dialog--trace-collapsed-p trace)
                                  (cdr sly-trace-dialog--collapse-chars)
                                (car sly-trace-dialog--collapse-chars))
                              #'(lambda (button)
                                  (sly-trace-dialog--set-collapsed
                                   (not (sly-trace-dialog--trace-collapsed-p
                                         trace))
                                   trace
                                   button))))


(defun sly-trace-dialog--insert-trace (trace)
  (let* ((id (sly-trace-dialog--trace-id trace))
         (parent (sly-trace-dialog--trace-parent trace))
         (has-children-p (sly-trace-dialog--trace-children-end trace))
         (indent-spec (sly-trace-dialog--make-indent
                       (sly-trace-dialog--trace-depth trace)
                       "`--"))
         (indent-summary (sly-trace-dialog--make-indent
                          (sly-trace-dialog--trace-depth trace)
                          "   "))
         (autofollow-fn (sly-trace-dialog--make-autofollow-fn id))
         (id-string (sly-trace-dialog--button
                     (format "%4s" id)
                     #'(lambda (_button)
                         (sly-eval-async
                             `(swank-trace-dialog:report-trace-detail
                               ,id)
                           #'sly-trace-dialog--open-detail))))
         (spec (sly-trace-dialog--trace-spec trace))
         (summary (cl-loop for (type objects marker) in
                           `((:arg    ,(sly-trace-dialog--trace-args trace)
                                      " > ")
                             (:retval ,(sly-trace-dialog--trace-retlist trace)
                                      " < "))
                           concat (cl-loop for object in objects
                                           concat "      "
                                           concat indent-summary
                                           concat marker
                                           concat (sly-trace-dialog--format-part
                                                   (cl-first object)
                                                   (cl-second object)
                                                   id
                                                   type)
                                           concat "\n"))))
    (puthash id trace sly-trace-dialog--traces)
    ;; insert and propertize the text
    ;;
    (setf (sly-trace-dialog--trace-beg trace) (point-marker))
    (insert id-string " ")
    (insert indent-spec)
    (if has-children-p
        (insert (sly-trace-dialog--make-collapse-button trace))
      (setf (sly-trace-dialog--trace-collapse-button-marker trace)
            (point-marker))
      (insert "-"))
    (insert (format " %s\n" spec))
    (setf (sly-trace-dialog--trace-summary-beg trace) (point-marker))
    (insert summary)
    (setf (sly-trace-dialog--trace-end trace) (point-marker))
    (set-marker-insertion-type (sly-trace-dialog--trace-beg trace) t)

    (add-text-properties (sly-trace-dialog--trace-beg trace)
                         (sly-trace-dialog--trace-end trace)
                         (list 'sly-trace-dialog--id id
                               'point-entered autofollow-fn
                               'point-left autofollow-fn))
    ;; respect brief mode and collapsed state
    ;;
    (cl-loop for condition in (list sly-trace-dialog-hide-details-mode
                                    (sly-trace-dialog--trace-collapsed-p trace))
             when condition
             do (sly-trace-dialog--hide-unhide
                 (sly-trace-dialog--trace-summary-beg
                  trace)
                 (sly-trace-dialog--trace-end trace)
                 1))
    (cl-loop for tr = trace then parent
             for parent = (sly-trace-dialog--trace-parent tr)
             while parent
             when (sly-trace-dialog--trace-collapsed-p parent)
             do (sly-trace-dialog--hide-unhide
                 (sly-trace-dialog--trace-beg trace)
                 (sly-trace-dialog--trace-end trace)
                 (+ 1
                    (or (get-text-property (sly-trace-dialog--trace-beg parent)
                                           'sly-trace-dialog--hidden-level)
                        0)))
             (cl-return))
    ;; maybe add the collapse-button to the parent in case it didn't
    ;; have one already
    ;;
    (when (and parent
               (sly-trace-dialog--trace-collapse-button-marker parent))
      (sly-trace-dialog--maintaining-properties
          (sly-trace-dialog--trace-collapse-button-marker parent)
        (delete-char 1)
        (insert (sly-trace-dialog--make-collapse-button parent))
        (setf (sly-trace-dialog--trace-collapse-button-marker parent)
              nil)))
    ;; draw the tree lines
    ;;
    (when parent
      (sly-trace-dialog--draw-tree-lines (sly-trace-dialog--trace-beg trace)
                                           (+ 2 (length indent-spec))
                                           'up))
    (when has-children-p
      (sly-trace-dialog--draw-tree-lines (sly-trace-dialog--trace-beg trace)
                                           (+ 5 (length indent-spec))
                                           'down))
    ;; set the "children-end" slot
    ;;
    (unless (sly-trace-dialog--trace-children-end trace)
      (cl-loop for parent = trace
               then (sly-trace-dialog--trace-parent parent)
               while parent
               do
               (setf (sly-trace-dialog--trace-children-end parent)
                     (sly-trace-dialog--trace-end trace))))))

(defun sly-trace-dialog--render-trace (trace)
  ;; Render the trace entry in the appropriate place.
  ;;
  ;; A trace becomes a few lines of slightly propertized text in the
  ;; buffer, inserted by `sly-trace-dialog--insert-trace', bound by
  ;; point markers that we use here.
  ;;
  ;; The new trace might be replacing an existing one, or otherwise
  ;; must be placed under its existing parent which might or might not
  ;; be the last entry inserted.
  ;;
  (let ((existing (sly-trace-dialog--find-trace
                   (sly-trace-dialog--trace-id trace)))
        (parent (sly-trace-dialog--trace-parent trace)))
    (cond (existing
           ;; Other traces might already reference `existing' and with
           ;; need to maintain that eqness. Best way to do that is
           ;; destructively modify `existing' with the new retlist...
           ;;
           (setf (sly-trace-dialog--trace-retlist existing)
                 (sly-trace-dialog--trace-retlist trace))
           ;; Now, before deleting and re-inserting `existing' at an
           ;; arbitrary point in the tree, note that it's
           ;; "children-end" marker is already non-nil, and informs us
           ;; about its parenthood status. We want to 1. leave it
           ;; alone if it's already a parent, or 2. set it to nil if
           ;; it's a leaf, thus forcing the needed update of the
           ;; parents' "children-end" marker.
           ;;
           (when (= (sly-trace-dialog--trace-children-end existing)
                    (sly-trace-dialog--trace-end existing))
             (setf (sly-trace-dialog--trace-children-end existing) nil))
           (delete-region (sly-trace-dialog--trace-beg existing)
                          (sly-trace-dialog--trace-end existing))
           (goto-char (sly-trace-dialog--trace-end existing))
           ;; Remember to set `trace' to be `existing'
           ;;
           (setq trace existing))
          (parent
           (goto-char (1+ (sly-trace-dialog--trace-children-end parent))))
          (;; top level trace
           t
           (goto-char (point-max))))
    (goto-char (line-beginning-position))
    (sly-trace-dialog--insert-trace trace)))

(defun sly-trace-dialog--update-tree (tuples)
  (save-excursion
    (sly-trace-dialog--refresh
        (:overlay sly-trace-dialog--tree-overlay
                  :dont-erase t)
      (cl-loop for tuple in tuples
               for parent = (sly-trace-dialog--find-trace (cl-second tuple))
               for trace = (sly-trace-dialog--make-trace
                            :id (cl-first tuple)
                            :parent parent
                            :spec (cl-third tuple)
                            :args (cl-fourth tuple)
                            :retlist (cl-fifth tuple)
                            :depth (if parent
                                       (1+ (sly-trace-dialog--trace-depth
                                            parent))
                                     0))
               do (sly-trace-dialog--render-trace trace)))))

(defun sly-trace-dialog--clear-local-tree ()
  (set (make-local-variable 'sly-trace-dialog--fetch-key)
       (cl-gensym "sly-trace-dialog-fetch-key-"))
  (set (make-local-variable 'sly-trace-dialog--traces)
       (make-hash-table))
  (sly-trace-dialog--refresh
      (:overlay sly-trace-dialog--tree-overlay))
  (sly-trace-dialog--update-progress nil))

(defun sly-trace-dialog--on-new-results (results &optional recurse)
  (cl-destructuring-bind (tuples remaining reply-key)
      results
    (cond ((and sly-trace-dialog--fetch-key
                (string= (symbol-name sly-trace-dialog--fetch-key)
                         (symbol-name reply-key)))
           (sly-trace-dialog--update-tree tuples)
           (sly-trace-dialog--update-progress
            remaining
            (and recurse
                 (cl-plusp remaining))
            t)
           (when (and recurse
                      (not (prog1 sly-trace-dialog--stop-fetching
                             (setq sly-trace-dialog--stop-fetching nil)))
                      (cl-plusp remaining))
             (sly-eval-async `(swank-trace-dialog:report-partial-tree
                                 ',reply-key)
               #'(lambda (results) (sly-trace-dialog--on-new-results
                                    results
                                    recurse))))))))


;;;; Interactive functions
;;;
(defun sly-trace-dialog-fetch-specs ()
  "Refresh just list of traced specs."
  (interactive)
  (sly-eval-async `(swank-trace-dialog:report-specs)
    #'sly-trace-dialog--open-specs))

(defun sly-trace-dialog-fetch-progress ()
  (interactive)
  (sly-eval-async
      '(swank-trace-dialog:report-total)
    #'(lambda (total)
        (sly-trace-dialog--update-progress
         total))))

(defun sly-trace-dialog-fetch-status ()
  "Refresh just the status part of the SLY Trace Dialog"
  (interactive)
  (sly-trace-dialog-fetch-specs)
  (sly-trace-dialog-fetch-progress))

(defun sly-trace-dialog-clear-fetched-traces (&optional interactive)
  "Clear local and remote traces collected so far"
  (interactive "p")
  (when (or (not interactive)
            (y-or-n-p "Clear all collected and fetched traces?"))
    (sly-eval-async
        '(swank-trace-dialog:clear-trace-tree)
      #'(lambda (_ignored)
          (sly-trace-dialog--clear-local-tree)))))

(defun sly-trace-dialog-fetch-traces (&optional recurse)
  (interactive "P")
  (setq sly-trace-dialog--stop-fetching nil)
  (sly-eval-async `(swank-trace-dialog:report-partial-tree
                      ',sly-trace-dialog--fetch-key)
    #'(lambda (results) (sly-trace-dialog--on-new-results results
                                                            recurse))))

(defun sly-trace-dialog-next-button (&optional goback)
  (interactive)
  (let ((finder (if goback
                    #'previous-single-property-change
                  #'next-single-property-change)))
    (cl-loop for pos = (funcall finder (point) 'action)
             while pos
             do (goto-char pos)
             until (get-text-property pos 'action))))

(defun sly-trace-dialog-prev-button ()
  (interactive)
  (sly-trace-dialog-next-button 'goback))

(defvar sly-trace-dialog-after-toggle-hook nil
  "Hooks run after toggling a dialog-trace")

(defun sly-trace-dialog-toggle-trace (&optional using-context-p)
  "Toggle the dialog-trace of the spec at point.

When USING-CONTEXT-P, attempt to decipher lambdas. methods and
other complicated function specs."
  (interactive "P")
  ;; Notice the use of "spec strings" here as opposed to the
  ;; proper cons specs we use on the swank side.
  ;;
  ;; Notice the conditional use of `sly-trace-query' found in
  ;; swank-fancy-trace.el
  ;;
  (let* ((spec-string (if using-context-p
                          (sly-extract-context)
                        (sly-symbol-at-point)))
         (spec-string (if (fboundp 'sly-trace-query)
                          (sly-trace-query spec-string)
                        spec-string)))
    (message "%s" (sly-eval `(swank-trace-dialog:dialog-toggle-trace
                                (swank::from-string ,spec-string))))
    (run-hooks 'sly-trace-dialog-after-toggle-hook)))

(defun sly-trace-dialog--update-existing-dialog ()
  (let ((existing (sly-trace-dialog--live-dialog)))
    (when existing
      (with-current-buffer existing
        (sly-trace-dialog-fetch-status)))))

(add-hook 'sly-trace-dialog-after-toggle-hook
          'sly-trace-dialog--update-existing-dialog)

(defun sly-trace-dialog-toggle-complex-trace ()
  "Toggle the dialog-trace of the complex spec at point.

See `sly-trace-dialog-toggle-trace'."
  (interactive)
  (sly-trace-dialog-toggle-trace t))

(defun sly-trace-dialog (&optional clear-and-fetch)
  "Show trace dialog and refresh trace collection status.

With optional CLEAR-AND-FETCH prefix arg, clear the current tree
and fetch a first batch of traces."
  (interactive "P")
  (with-current-buffer
      (pop-to-buffer (sly-trace-dialog--ensure-buffer))
    (sly-trace-dialog-fetch-status)
    (when (or clear-and-fetch
              (null sly-trace-dialog--fetch-key))
      (sly-trace-dialog--clear-local-tree))
    (when clear-and-fetch
      (sly-trace-dialog-fetch-traces nil))))

(provide 'sly-trace-dialog)