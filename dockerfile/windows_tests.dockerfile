# escape=`
# Microsoft MCR manifest and MinGit release digest verified 2026-11-08.
FROM mcr.microsoft.com/windows/servercore:ltsc2022@sha256:b52799a67fa596d4bddcd82ae1dab0077a84767fbc33c7342b72b53ecc71ad09 AS devel
SHELL ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
COPY script/docker/download_library.ps1 C:/tools/download_library.ps1
COPY script/docker/install_min_git.ps1 C:/tools/install_min_git.ps1
RUN C:/tools/install_min_git.ps1
COPY script/docker/install_go.ps1 C:/tools/install_go.ps1
RUN C:/tools/install_go.ps1
COPY script/docker/install_managed_tools.ps1 C:/tools/install_managed_tools.ps1
RUN C:/tools/install_managed_tools.ps1
# The pinned Windows image has case-sensitive Docker metadata but Windows treats
# Path case-insensitively. Do not expand ${PATH}: it can erase system tools.
ENV PATH="C:\git\cmd;C:\go\bin;C:\pwsh;C:\dotnet;C:\actionlint;C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0" GIT_OPTIONAL_LOCKS="0" GOTOOLCHAIN="local" GOPROXY="off" GOSUMDB="off" GOFLAGS="-mod=vendor" CGO_ENABLED="0" GOWORK="off" GOENV="off" DOTNET_ROOT="C:/dotnet" DOTNET_CLI_TELEMETRY_OPTOUT="1" DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1" DOTNET_GENERATE_ASPNET_CERTIFICATE="false" DOTNET_NOLOGO="1" WINDOWS_SETUP_MANAGED_PACKAGE_PATH="C:/tools/cache/dotnet-coverage.17.14.1.nupkg" WINDOWS_SETUP_ACTIONLINT="C:/actionlint/actionlint.exe" WINDOWS_SETUP_PESTER_PACKAGE_PATH="C:/tools/cache/pester.6.0.0.zip"
COPY script/test/ci_tasks.ps1 C:/tools/ci_tasks.ps1
COPY script/docker/container_health.ps1 C:/tools/container_health.ps1
RUN $ErrorActionPreference='Stop'; . C:/tools/ci_tasks.ps1; Assert-CIRequiredTools -Managed
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ". C:/tools/ci_tasks.ps1; . C:/tools/container_health.ps1; if (Test-ContainerToolHealth) { exit 0 } else { exit 1 }"]
USER ContainerUser
WORKDIR C:/workspace
CMD ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile"]

FROM devel AS test
COPY script/docker/container_test.ps1 C:/tools/container_test.ps1
CMD ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:/tools/container_test.ps1"]
