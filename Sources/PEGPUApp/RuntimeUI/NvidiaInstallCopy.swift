enum NvidiaInstallCopy {
    static let cardNotice = "PEGPU uses a standard Debian image and does not ship, endorse, or modify GPU vendor drivers. NVIDIA packages are installed from NVIDIA repositories inside the Linux VM."

    static let modalTitle = "Install NVIDIA Linux Driver"

    static let modalInfo = "PEGPU does not include or distribute GPU vendor drivers. GPU drivers are installed inside the Linux VM from vendor or distribution repositories."

    static let ownershipNotice = "PEGPU does not include or distribute GPU vendor drivers. GPU drivers are installed inside the Linux VM from vendor or distribution repositories. NVIDIA, CUDA, AMD, ROCm, and other names belong to their owners."

    static let installNotice = "This installer configures NVIDIA repositories in Debian, then runs the package install below inside the VM. PEGPU is not affiliated with NVIDIA and does not ship NVIDIA drivers."

    static let acknowledgement = "I want to install the NVIDIA Linux driver packages inside this Debian VM."

    static let commandPreview = """
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \\
      -o Dpkg::Options::=--force-confdef \\
      -o Dpkg::Options::=--force-confold \\
      nvidia-driver-pinning-595.71.05 \\
      nvidia-open=595.71.05-1 \\
      cuda-toolkit-13-2=13.2.1-1
    """
}
