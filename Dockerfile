FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# Install the SqlServer PowerShell module
RUN pwsh -NoLogo -NonInteractive -Command \
    "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
     Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers"

WORKDIR /app

COPY entrypoint.ps1 .
COPY LadderTracker.ps1 .

# Output directories - overlaid by the volume mount at runtime.
# Creating them here ensures they exist if the volume is empty on first run.
RUN mkdir -p /data/logs \
             /data/MMR/AllPartipants \
             /data/MMR/DailyWinner \
             /data/MMR/DailyLoser \
             /data/SQLOutput

ENTRYPOINT ["pwsh", "-NoLogo", "-NonInteractive", "-File", "/app/entrypoint.ps1"]
