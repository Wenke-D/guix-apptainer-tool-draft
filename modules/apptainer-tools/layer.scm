(define-module (apptainer-tools layer)
  #:use-module (guix gexp)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (apptainer-tools store-squashfs)
  #:export (apptainer-layer
            apptainer-layer?
            apptainer-layer-name
            apptainer-layer-packages
            apptainer-layer-compression
            apptainer-layer-compression-level
            apptainer-layer-closure
            apptainer-layer-marker))

;; A read-only layer for 'apptainer run --overlay LAYER:ro IMAGE': a squashfs
;; holding the closure of PACKAGES under the store.
(define-record-type* <apptainer-layer>
  apptainer-layer make-apptainer-layer
  apptainer-layer?
  (name              apptainer-layer-name)
  (packages          apptainer-layer-packages)
  (compression       apptainer-layer-compression       ;as for images
                     (default "gzip"))
  (compression-level apptainer-layer-compression-level
                     (default #f)))

(define (apptainer-layer-closure layer)
  "Return a file listing the store items that LAYER holds."
  (references-file
   (profile
    (content (packages->manifest (apptainer-layer-packages layer)))
    (hooks '())
    (locales? #f))
   (string-append (apptainer-layer-name layer) "-closure")))

(define (apptainer-layer-marker layer)
  "Return a gexp for the name of the file that marks LAYER in the container,
derived from the store items it holds."
  #~(string-append (string-take (basename #$(apptainer-layer-closure layer))
                                32)
                   "-" #$(apptainer-layer-name layer)))

(define (layer-tree layer)
  (computed-file
   (string-append (apptainer-layer-name layer) "-layer-tree")
   #~(let ((marker (string-append #$output "/.layers/"
                                  #$(apptainer-layer-marker layer))))
       (mkdir #$output)
       (mkdir (dirname marker))
       (call-with-output-file marker (const #t)))))

(define-gexp-compiler (apptainer-layer-compiler (layer <apptainer-layer>)
                                                system target)
  (lower-object
   (store-squashfs (string-append (apptainer-layer-name layer) ".squashfs")
                   (layer-tree layer)
                   (list (apptainer-layer-closure layer))
                   #:compression (apptainer-layer-compression layer)
                   #:compression-level
                   (apptainer-layer-compression-level layer))
   system #:target target))
