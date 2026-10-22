;;; Commentary:
;;;
;;; Apptainer images of Guix packages, with the heavy dependencies in
;;; separate layers that are mounted as overlays.
;;;
;;;   (apptainer-tools image)           the image record and its compiler
;;;   (apptainer-tools layer)           the layer record, its closure, marker
;;;                                     and compiler
;;;   (apptainer-tools store-squashfs)  a squashfs of a tree and store items,
;;;                                     which both compilers build
;;;
;;; Code:

(define-module (apptainer-tools)
  #:use-module (apptainer-tools image)
  #:use-module (apptainer-tools layer)
  #:re-export (apptainer-image
               apptainer-image?
               apptainer-layer
               apptainer-layer?))
