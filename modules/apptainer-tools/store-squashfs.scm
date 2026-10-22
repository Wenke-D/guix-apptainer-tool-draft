(define-module (apptainer-tools store-squashfs)
  #:use-module (guix gexp)
  #:use-module (gnu packages compression)
  #:export (store-squashfs))

;; NAME:  of the squashfs file.
;; TREE:  a directory whose contents become the root of the file system.
;; ITEMS, EXCLUDE: lists of 'references-file' outputs; the store items listed
;;        in ITEMS but in none of EXCLUDE are copied in, under the store.
;; COMPRESSION: a mksquashfs compressor; COMPRESSION-LEVEL: #f for its default.
(define* (store-squashfs name tree items
                         #:key (exclude '()) compression compression-level)
  (computed-file
   name
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils)
                      (srfi srfi-1))

         (define (read-items files)
           (delete-duplicates
            (append-map (lambda (file) (call-with-input-file file read))
                        files)))

         (for-each (lambda (item)
                     (let ((target (string-append "root" item)))
                       (mkdir-p (dirname target))
                       (copy-recursively item target
                                         #:keep-permissions? #t
                                         #:log (%make-void-port "w"))))
                   (lset-difference string=?
                                    (read-items (list #$@items))
                                    (read-items (list #$@exclude))))

         ;; Last: it makes the root directory read-only, as in the store.
         (copy-recursively #$tree "root"
                           #:keep-permissions? #t
                           #:log (%make-void-port "w"))

         (invoke #+(file-append squashfs-tools "/bin/mksquashfs")
                 "root" #$output
                 "-noappend" "-all-root" "-no-xattrs" "-quiet"
                 "-all-time" "1" "-mkfs-time" "1"
                 "-comp" #$compression
                 #$@(if compression-level
                        (list "-Xcompression-level"
                              (number->string compression-level))
                        '()))))))
