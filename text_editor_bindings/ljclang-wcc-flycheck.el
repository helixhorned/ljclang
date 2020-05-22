
;; Copyright (C) 2019-2020 Philipp Kutin

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

(require 'flycheck)

;; Usage (for now):
;;  (load "/path/to/.../ljclang-wcc-flycheck.el")

;; TODO:
;;  make usable with 'require'.

(defun ljclang-wcc-check-diags-request (_)
  (let*
      ((res
        ;; Execute 'wcc-client -c' to check it being properly set up.
        ;; ignore-errors is used so that we catch the case when the executable is not found.
        ;;  TODO: find out: redundant because flycheck checks this before?
        (ignore-errors (call-process "wcc-client" nil nil nil "-C")))
       (message
        (cond
         ((null res) "failed to execute wcc-client")
         ((stringp res) (concat "wcc-client exited with signal: " res))
         ((numberp res)
          (case res
            ;; KEEPINSYNC with wcc-client's exit codes.
            (0 "success")
            (1 "failed creating FIFO")
            (2 "UNEXPECTED ERROR")  ; malformed command/args, shouldn't happen with '-c'.
            (3 "server not running")
            ;; May indicate that:
            ;;  - it is an exit code >=100 (malformed/unexpected reply from server), or
            ;;  - an update here is necessary.
            (t "UNEXPECTED EXIT CODE")
            ))
         )))
    (list
     (flycheck-verification-result-new
      :label "wcc-client check"
      :message message
      :face (if (equal message "success") 'success '(bold error))
      ))
    )
)

(defun ljclang-wcc--get-file-info-string (str)
  (if (string-equal str "1!")
      ;; The file is a source file with a count of including TUs of one. Do not
      ;; show the count as it contains little information. (Most source files
      ;; only participate in one translation unit. We are interested in headers,
      ;; and source files which participate in zero or more than one TUs.)
      ""
    ;; NOTE: it is deliberate that we pass through a count of zero. Assuming
    ;;  that wcc-server is finished, this means that a file (even a source!) is
    ;;  not reachable by any of the compile commands the it was instructed with.
    (if (string-match-p "^[0-9]+[\+\?]?!?$" str)
        (concat "⇝" str)
      ;; Three crosses: wcc-client returned a string of unexpected form.
      ;; We forgot to update the string validation above?
      "☓☓☓")))

(defvar-local ljclang-wcc--buffer-file-info-string nil)

(defun ljclang-wcc--parse-with-patterns (output checker buffer)
  "Parse OUTPUT from CHECKER with error patterns.

Wraps `flycheck-parse-with-patterns' to additionally set a buffer-local
suffix for the 'FlyC' status text.
"
  ;; Match the first line of the wcc-client invocation, which we expect is the output of
  ;;  the "fileinfo including-tu-count" command.
  (let* ((firstLine (progn (if (string-match "^\\([^\n]+\\)\n" output)
                               (match-string 1 output))))
         (infoStr
          (if firstLine
              (ljclang-wcc--get-file-info-string firstLine)
            ;; High voltage sign: first line of output has unexpected form. This should not
            ;; happen unless wcc-client is mismatched. (We assume that this function is
            ;; called only if the checker process exited with a non-zero status.)
            "⚡")))
    ;; Set the mode line suffix.
    (setq ljclang-wcc--buffer-file-info-string infoStr))
  (flycheck-parse-with-patterns output checker buffer)
)

(flycheck-define-checker c/c++-wcc
  "A C/C++ syntax checker using watch_compile_commands.

See URL `https://github.com/helixhorned/ljclang/tree/rpi'."
  ;; TODO: remove 'rpi' once it is merged to master.
  :command ("wcc-client" "-b"
            "fileinfo" "including-tu-count" source-original
            "@@"
            "diags" source-original)

  :error-parser ljclang-wcc--parse-with-patterns
  :error-patterns
  (
   ;;; Same as for 'c/c++-clang' checker, but with '<stdin>' removed.

   ;; TODO: if possible, make known to Flycheck:
   ;;  - the error group, e.g. [Semantic Issue] or [Parse Issue]
   ;;  - the warning ID, e.g. [-W#warnings]
   (info line-start (file-name) ":" line ":" column
         ": note: " (optional (message)) line-end)
   (warning line-start (file-name) ":" line ":" column
            ": warning: " (optional (message)) line-end)
   (error line-start (file-name) ":" line ":" column
          ": " (or "fatal error" "error") ": " (optional (message)) line-end)

   ;;; Specific to ljclang-wcc-flycheck.el

   ;; NOTE: Flycheck flags an invocation of a checker as "suspicious" (and outputs a lengthy
   ;;  user-facing message asking to update Flycheck and/or file a Flycheck bug report) if
   ;;  its exit code is non-zero but no errors were found (using the matching rules defined
   ;;  in the checker). So, make the client error states known to Flycheck.
   ;;
   ;; TODO: however, why does Flycheck not enter the 'errored' ("FlyC!") state when
   ;;  wcc-client exits with a non-zero code? We do not want to miss any kind of errors!
   ;;  Need to research Flycheck error handling further.

   ;; Error occurring in the client.
   (error "ERROR: " (message) line-end)
   ;; Error reported back by the server.
   (error "remote: ERROR: " (message) line-end)
   )

  :modes (c-mode c++-mode)
  :predicate flycheck-buffer-saved-p

  ;; NOTE: this is called only on a manual flycheck-verify-setup invocation.
  :verify ljclang-wcc-check-diags-request
)

(defun ljclang-wcc-mode-line-status-text (&optional status)
  "Get a text describing STATUS for use in the mode line.

Can be used instead of `flycheck-mode-line-status-text' in the
value for `flycheck-mode-line'.
"
  (concat
   (flycheck-mode-line-status-text status)
   (let ((checker (flycheck-get-checker-for-buffer)))
     (if (eq checker 'c/c++-wcc)
         ljclang-wcc--buffer-file-info-string
       ""))))
