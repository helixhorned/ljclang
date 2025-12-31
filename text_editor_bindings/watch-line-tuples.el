;;; watch-line-tuples.el --- interface to watch_line_tuples.lua -*- lexical-binding: t -*-

;; Copyright (C) 2026 Philipp Kutin

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


;;; User Variables

(defgroup watch-line-tuples nil
  "Front-end to `watch_line_tuples.lua'"
  :prefix "watch-line-tuples-"
  :group 'external
  :group 'tools
  :link '(url-link :tag "ljclang GitHub repo" "https://github.com/helixhorned/ljclang"))

(defcustom watch-line-tuples-an-executable "watch_line_tuples.lua"
  "Absolute or relative path to `watch_line_tuples.lua' program."
  :type '(file))

(defcustom watch-line-tuples-arg-context-line-counts "0,1"
  "Passed to `watch_line_tuples.lua' as `<context-line-counts>' argument."
  :type '(string))

(defcustom watch-line-tuples-arg-files-file ""
  "Passed to `watch_line_tuples.lua' as `<files-file>' argument."
  ;; TODO [BUFFER_FILTER]: use filter the set of buffers in which this mode is active.
  ;;  - For example, using the contents of the file.
  ;;  - Conceptually, make independent:
  ;;    1. the `watch_line_tuples.lua' process
  ;;    2. any buffers that may want to interact with it (possibly with behavior like
  ;;       "closing last such buffer exits the mode")
  :type '(file :must-match t))

(defcustom watch-line-tuples-arg-max-query-result-lines 10
  "Passed to `watch_line_tuples.lua' as `<max-query-result-lines>' argument. Must be nonnegative.

Providing a value of zero is only useful for debugging."
  :type '(natnum))

(defcustom watch-line-tuples-wait-for-output-timeout 0.1
  "Timeout (in seconds) for waiting for output after issuing a command to `watch_line_tuples.lua'.

Note: this is done from `post-command-hook'."
  :type '(float))


;;;; Helper functions

(defun watch-line-tuples--nonempty-string-p (obj)
  (and (stringp obj) (not (string-empty-p obj))))

(defun watch-line-tuples--get-empty-buffer (name &optional enable-grep-mode)
  (let ((buf (get-buffer-create name t)))
	(with-current-buffer buf
	  (when enable-grep-mode
		;; TODO: define a derived mode instead. It can have:
		;;  - read-write initially?
		;;  - a reduced keymap
		(grep-mode)
		(read-only-mode -1))
	  (erase-buffer))
	buf))

(defun watch-line-tuples--info-for-text-around (ctx-lct)
  (cl-assert (integerp ctx-lct) t)
  (cl-assert (>= ctx-lct 0) t)
  (let* ((bpos (pos-bol (1+ (- ctx-lct))))
		 (epos (pos-bol (+ 2 ctx-lct)))
		 ;; Line numbers
		 (blnum (line-number-at-pos bpos))
		 (clnum (line-number-at-pos))
		 (elnum (line-number-at-pos epos))
		 ;; Counts of context lines which we have, and those we miss (due to borders)
		 (bhave-lct (- clnum blnum))
		 (ehave-lct (- elnum clnum 1))
		 (bmiss-lct (- ctx-lct bhave-lct))
		 (emiss-lct (- ctx-lct ehave-lct)))
	(cl-assert (<= 0 bmiss-lct ctx-lct) t)
	(cl-assert (<= 0 emiss-lct (1+ ctx-lct)) t)
;	(message "%s" (vector bpos epos '/ blnum clnum elnum '/ bmiss-lct emiss-lct))
	(vector bpos epos bmiss-lct emiss-lct)))


;;;; Private state

(defvar watch-line-tuples--process)
(defvar watch-line-tuples--ready)

;; Cache for checks of whether `watch-line-tuples--post-command-hook' is to proceed:
(defvar watch-line-tuples--last-buffer)
(defvar watch-line-tuples--last-buffer-ok)
(defvar watch-line-tuples--last-line-number 0)

(defvar watch-line-tuples--mode-line)
(defvar watch-line-tuples--max-ctx-lines)
(defvar watch-line-tuples--query-command)


;;;; Mode definition

(defun watch-line-tuples--reset-check-cache ()
  (setq watch-line-tuples--last-buffer nil)
  (setq watch-line-tuples--last-buffer-ok nil)
  (setq watch-line-tuples--last-line-number 0))

(defun watch-line-tuples--set-mode-line (suffix)
  (setq watch-line-tuples--mode-line (format " Ldup:%s" suffix)))

(defun watch-line-tuples--initialize (ctx-line-counts-str)
  (cl-assert (stringp ctx-line-counts-str) t)
  (setq watch-line-tuples--ready nil)
  (watch-line-tuples--reset-check-cache)
  (watch-line-tuples--set-mode-line "⌛")
  (let* ((split-result (split-string ctx-line-counts-str ","))
		 (last-str (car (last split-result)))
		 (max-ctx (string-to-number last-str))
		 (line-span (1+ (* 2 max-ctx))))
	(setq watch-line-tuples--max-ctx-lines max-ctx)
	(setq watch-line-tuples--query-command (format "q%d\n" line-span))))

(defun watch-line-tuples--teardown ()
  ;; Not all private state is reset. But at least variables referencing objects.
  (setq watch-line-tuples--process nil)
  (setq watch-line-tuples--ready nil)
  (watch-line-tuples--reset-check-cache))

(defun watch-line-tuples--handle-followup-output (process output)
  (cl-assert (eq process watch-line-tuples--process) t)
  (let ((buf (process-buffer process)))
	(when (buffer-live-p buf)
	  (with-current-buffer (process-buffer process)
		(erase-buffer)
		(insert output)))))

(defun watch-line-tuples--handle-initial-output (process output)
  (cl-assert (eq process watch-line-tuples--process) t)
  (let ((buf (process-buffer process)))
	(when (buffer-live-p buf)
	  (with-current-buffer buf
		(insert output))))
  (setq watch-line-tuples--ready t)
  (watch-line-tuples--set-mode-line "✓")
  (force-mode-line-update)
  (set-process-filter process 'watch-line-tuples--handle-followup-output))

(defun watch-line-tuples--buffer-ok-p (buf)
  (cl-assert (bufferp buf) t)
  ;; TODO: see BUFFER_FILTER
  (buffer-file-name buf))

;; NOTE: Must be relatively cheap to compute.
(defun watch-line-tuples--should-do-post-command ()
  (and
   watch-line-tuples--ready
   (let ((buf (current-buffer)))
	 (when (not (eq watch-line-tuples--last-buffer buf))
	   (setq watch-line-tuples--last-buffer buf)
	   (setq watch-line-tuples--last-buffer-ok (watch-line-tuples--buffer-ok-p buf))
	   (setq watch-line-tuples--last-line-number 0))
	 watch-line-tuples--last-buffer-ok)
   (let ((line-num (line-number-at-pos nil t)))
	 (when (/= line-num watch-line-tuples--last-line-number)
	   (setq watch-line-tuples--last-line-number line-num)
	   t))))

;; REMINDER: this MUST be cheap to compute. Emacs does not provide finer-grained hooks.
(defun watch-line-tuples--post-command-hook ()
  (when (watch-line-tuples--should-do-post-command)
	(let* ((proc watch-line-tuples--process)
		   (ctx-lct watch-line-tuples--max-ctx-lines)
		   (info (watch-line-tuples--info-for-text-around ctx-lct))
		   (bpos (aref info 0))
		   (epos (aref info 1))
		   (bmiss-lct (aref info 2))
		   (emiss-lct (aref info 3)))
	  (process-send-string proc watch-line-tuples--query-command)
	  (if (= 0 bmiss-lct emiss-lct)
		  ;; Point is at a line that provides enough context: source the buffer directly.
		  (process-send-region proc bpos epos)
		;; Point is at a border line wrt the context: extract and pad as needed.
		(let* ((str-to-pad (buffer-substring-no-properties bpos epos))
			   (padded-str (concat
							(make-string bmiss-lct ?\n)
							str-to-pad
							(make-string emiss-lct ?\n))))
		  (process-send-string proc padded-str)))
	  (accept-process-output proc watch-line-tuples-wait-for-output-timeout nil t))))

(defun watch-line-tuples--sentinel (process event)
  (cl-assert (eq process watch-line-tuples--process) t)
  (message "%s: %s" process event)
  (when (not (process-live-p process))
	(watch-line-tuples-mode -1)))

(defun watch-line-tuples--handle-enable ()
  (let* ((exe-abs-or-rel watch-line-tuples-an-executable)
		 (exe-type-ok (watch-line-tuples--nonempty-string-p exe-abs-or-rel))
		 (exe-abs (and exe-type-ok (executable-find exe-abs-or-rel)))
		 (ctx-line-counts watch-line-tuples-arg-context-line-counts)
		 (files-file watch-line-tuples-arg-files-file)
		 (max-res-lines watch-line-tuples-arg-max-query-result-lines)
		 (bail
		  ;; TODO: is this correct? The documentation says that the mode variable *reflects*
		  ;;  the state instead of being a switch. However, from the body of the mode
		  ;;  *function* (the one passed to 'define-minor-mode'), we do not want to call the
		  ;;  function -- the recursion seems undesirable.
		  (lambda () (setq watch-line-tuples-mode nil)))
		 (msg (cond
			   ((not exe-type-ok)
				"Must set `watch-line-tuples-an-executable' to a nonempty string")
			   ((not exe-abs)
				"Must point `watch-line-tuples-an-executable' to an executable file")
			   ((not (watch-line-tuples--nonempty-string-p ctx-line-counts))
				"Must set `watch-line-tuples-arg-context-line-counts` to a nonempty string")
			   ((not (watch-line-tuples--nonempty-string-p files-file))
				"Must set `watch-line-tuples-arg-files-file' to a nonempty string")
			   ((not (file-regular-p files-file))
				"Must point `watch-line-tuples-arg-files-file' to a regular file")
			   ((not (and (integerp max-res-lines) (>= max-res-lines 0)))
				"Must set `watch-line-tuples-arg-max-query-result-lines' to a nonnegative integer")
			   )))
	(if msg
		(progn (message msg)
			   (funcall bail))
	  (let ((cmd-and-args (list exe-abs ctx-line-counts files-file (number-to-string max-res-lines))))
		(if (not (y-or-n-p (format "Start %s?" cmd-and-args)))
			(funcall bail)
		  (setq watch-line-tuples--process
				(make-process
				 :name "watch_line_tuples.lua"
				 :command cmd-and-args
				 :connection-type 'pipe
				 :noquery t
				 :buffer (watch-line-tuples--get-empty-buffer "*watch-line-tuples*" t)
;				 :stderr (watch-line-tuples--get-empty-buffer "*watch-line-tuples:stderr*")
				 :filter 'watch-line-tuples--handle-initial-output
				 :sentinel 'watch-line-tuples--sentinel))
		  (if (process-live-p watch-line-tuples--process)
			  (progn
				(watch-line-tuples--initialize ctx-line-counts)
				(add-hook 'post-command-hook #'watch-line-tuples--post-command-hook))
			(bail))
		  )))))

(defun watch-line-tuples--handle-disable ()
  (remove-hook 'post-command-hook #'watch-line-tuples--post-command-hook)
  (let ((proc watch-line-tuples--process))
	(when proc
	  (signal-process proc 'SIGTERM)
	  (accept-process-output proc 0.25)
	  (delete-process proc)))
  (watch-line-tuples--teardown))

(define-minor-mode watch-line-tuples-mode
  "Minor mode being a front-end to `watch_line_tuples.lua'."
  :global t
  :lighter watch-line-tuples--mode-line
  (if watch-line-tuples-mode
	  (watch-line-tuples--handle-enable)
	(watch-line-tuples--handle-disable)))

(provide 'watch-line-tuples)
