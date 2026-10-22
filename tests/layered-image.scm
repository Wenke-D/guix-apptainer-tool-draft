;; glibc is in the layer, not in this image, so the image runs only with the
;; layer as an overlay:
;;
;;   guix build -L modules -f tests/layer.scm -r coreutils.squashfs
;;   guix build -L modules -f tests/layered-image.scm -r hello-layered.squashfs
;;   apptainer run --overlay coreutils.squashfs:ro hello-layered.squashfs        # Hello, world!
;;   apptainer exec --overlay coreutils.squashfs:ro hello-layered.squashfs ls /  # ls from the layer
;;   apptainer run hello-layered.squashfs   # error: this image needs the layer ...-coreutils.squashfs
(use-modules (apptainer-tools)
             (gnu packages base))

(apptainer-image
 (name "hello-layered")
 (packages (list hello))
 (layers (list (load "layer.scm")))
 (run-script "exec hello \"$@\""))
