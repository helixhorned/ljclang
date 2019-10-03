
;; Copyright (C) 2019 Philipp Kutin

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

;; TODO: add license file.

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

(flycheck-define-checker c/c++-wcc
  "A C/C++ syntax checker using watch_compile_commands.

See URL `https://github.com/helixhorned/ljclang/tree/staging'."
  ;; TODO: remove 'staging' once it is merged to master.
  :command ("wcc-client" "diags" source-original)

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
