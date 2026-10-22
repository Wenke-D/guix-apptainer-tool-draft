(use-modules (apptainer-tools)
             (gnu packages base))

(apptainer-layer
 (name "coreutils")
 (packages (list coreutils)))
