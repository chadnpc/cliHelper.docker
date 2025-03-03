#!/usr/bin/env pwsh

#region    Classes
<#
.SYNOPSIS
  A module to provide object-oriented access to Docker resources (containers, images, networks, volumes, etc.) and their management.
.LINK
  Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
  # Run a container in detached mode, get the ID
  $containerId = [DockerTools]::Run("ubuntu", @("sleep", "infinity"), $true)
  Write-Host "Container ID: $containerId"

  # List all containers
  $containers = [DockerTools]::Ps($true)
  $containers | Format-Table

  # Stop the container
  [DockerTools]::Stop($containerId)

  # Remove the container
  [DockerTools]::Remove($containerId)

  # List images
  $images = [DockerTools]::Images()
  $images | Format-Table

  # Pull an image
  [DockerTools]::Pull("nginx:latest")

  # Using podman
  $containerId = [DockerTools]::Run("ubuntu", @("sleep", "infinity"), $true, $null, $null, @(), @(), $true, "podman")

  # Inspect the container
  $dockerTools = new-object DockerTools -ArgumentList "podman" # instantiate using previous version to inspect

  # List all running containers, then stop them.  PowerShell pipeline example.
  [DockerTools]::Ps() | ForEach-Object { [DockerTools]::Stop($_.ID) }

  # Exec a command in running container
  $containerId = [DockerTools]::Run("ubuntu", @("sleep", "infinity"), $true, -Name="testcontainer")
  [DockerTools]::ExecInContainer("testcontainer", @("ls", "-la", "/"))
  [DockerTools]::Stop("testcontainer")
  [DockerTools]::Remove("testcontainer")

  # Inspect volume, image, network
  $volume = [DockerTools]::CreateVolume("testVolume")
  [DockerTools]::InspectVolume("testVolume") | Format-List
  [DockerTools]::RemoveVolume("testVolume")

  [DockerTools]::Pull("ubuntu")
  [DockerTools]::InspectImage("ubuntu") | Format-List

  $network = [DockerTools]::CreateNetwork("testNetwork")
  [DockerTools]::InspectNetwork("testNetwork") | Format-List
  [DockerTools]::RemoveNetwork("testNetwork")
#>


class DockerTools {
  [string]$ClientBinary = "docker"  # Default to Docker, can be 'podman', 'nerdctl'
  [string]$Context
  [string]$Host
  [string]$LogLevel
  [bool]$Debug = $false

  # Compose-specific properties
  [string[]]$ComposeFiles = @()
  [string[]]$ComposeProfiles = @()
  [string]$ComposeEnvFile
  [string]$ComposeProjectName

  DockerTools([string]$ClientBinary = "docker", [string]$Context = $null, [string]$HostName = $null, [string]$LogLevel = "info", [bool]$Debug = $false) {
    $this.ClientBinary = $ClientBinary
    $this.Context = $Context
    $this.Host = $HostName
    $this.LogLevel = $LogLevel
    $this.Debug = $Debug
  }


  #region Private Methods
  hidden [string] Exec([string[]]$arguments) {

    # Add Default arguments
    if ($this.Debug) {
      $arguments = "--debug", $arguments
    }

    if ($this.LogLevel) {
      $arguments = "--log-level", $this.LogLevel, $arguments
    }

    if ($this.Host) {
      $arguments = "--host", $this.Host, $arguments
    }

    if ($this.Context) {
      $arguments = "--context", $this.Context, $arguments
    }

    if ($this.Debug) {
      Write-Host "Executing: $($this.ClientBinary) $($arguments -join ' ')" -ForegroundColor DarkGray
    }

    $process = [System.Diagnostics.Process]::Start(
      [System.Diagnostics.ProcessStartInfo]@{
        FileName               = $this.ClientBinary
        Arguments              = $arguments -join " "
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
        CreateNoWindow         = $true
      }
    )
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
      $stdErr = $process.StandardError.ReadToEnd()
      Write-Error -Message "$($this.ClientBinary) command failed: $($stdErr)" -Category NotInstalled
      throw "Docker command failed with exit code $($process.ExitCode): $($stdErr)"

    }

    return $process.StandardOutput.ReadToEnd()
  }

  #endregion

  #region Public Methods

  #region Container Management

  [string] Run([string]$image, [string[]]$command = @(), [bool]$detach = $false, [string]$name = $null, [hashtable]$env = $null, [string[]]$ports = @(), [string[]]$volumes = @(), [bool]$remove = $false) {
    $arguments = @("run")

    if ($detach) {
      $arguments += "--detach"
    }
    if ($remove) {
      $arguments += "--rm"
    }
    if ($name) {
      $arguments += "--name"
      $arguments += $name
    }

    if ($env) {
      foreach ($key in $env.Keys) {
        $arguments += "-e"
        $arguments += "$($key)=$($env[$key])"
      }
    }

    if ($ports) {
      foreach ($portMapping in $ports) {
        $arguments += "-p"
        $arguments += $portMapping
      }
    }

    if ($volumes) {
      foreach ($volumeMapping in $volumes) {
        $arguments += "-v"
        $arguments += $volumeMapping
      }
    }
    $arguments += $image
    $arguments += $command

    return $this.Exec($arguments)
  }

  [PSObject[]] Ps([bool]$all = $false) {
    $arguments = @("ps")

    if ($all) {
      $arguments += "-a"
    }

    $arguments += "--format", "json"

    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json
  }

  [void] Stop([string]$containerIdOrName) {
    $arguments = @("stop", $containerIdOrName)
    $this.Exec($arguments)
  }

  [void] Remove([string]$containerIdOrName, [bool]$force = $false) {
    $arguments = @("rm")
    if ($force) {
      $arguments += "--force"
    }
    $arguments += $containerIdOrName

    $this.Exec($arguments)
  }

  [string] Logs([string]$containerIdOrName) {
    $arguments = @("logs", $containerIdOrName)
    return $this.Exec($arguments)
  }

  [string] ExecInContainer([string]$containerIdOrName, [string[]]$command, [bool]$interactive = $false, [bool]$tty = $false) {
    $arguments = @("exec")

    if ($interactive) {
      $arguments += "-i"
    }

    if ($tty) {
      $arguments += "-t"
    }

    $arguments += $containerIdOrName
    $arguments += $command
    return $this.Exec($arguments)
  }

  #endregion

  #region Image Management

  [PSObject[]] Images() {
    $arguments = @("images", "--format", "json")
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json
  }

  [string] Pull([string]$imageName) {
    $arguments = @("pull", $imageName)
    return $this.Exec($arguments)
  }

  [void] RemoveImage([string]$imageIdOrName, [bool]$force = $false) {
    $arguments = @("rmi")
    if ($force) {
      $arguments += "--force"
    }
    $arguments += $imageIdOrName
    $this.Exec($arguments)
  }

  [PSObject] InspectImage([string]$imageIdOrName) {
    $arguments = @("image", "inspect", "--format", "json", $imageIdOrName)
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1  # docker image inspect returns an array; take the first one
  }

  #endregion

  #region Volume Management

  [PSObject[]] ListVolumes() {
    $arguments = @("volume", "ls", "--format", "json")
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json
  }
  [string] CreateVolume([string]$volumeName) {
    $arguments = @("volume", "create")
    if ($volumeName) {
      $arguments += $volumeName
    }

    return $this.Exec($arguments).Trim() #.Trim to get rid of newline that docker creates
  }

  [void] RemoveVolume([string]$volumeName, [bool]$force = $false) {
    $arguments = @("volume", "rm")
    if ($force) {
      $arguments += "--force"
    }

    $arguments += $volumeName
    $this.Exec($arguments)
  }

  [PSObject] InspectVolume([string]$volumeName) {
    $arguments = @("volume", "inspect", "--format", "json", $volumeName)
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1 # docker volume inspect returns an array; take the first one
  }

  [PSObject[]] ListNetworks() {
    $arguments = @("network", "ls", "--format", "json")
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json
  }

  [string] CreateNetwork([string]$networkName, [string]$driver = $null) {
    $arguments = @("network", "create")
    if ($driver) {
      $arguments += "--driver", $driver
    }
    $arguments += $networkName
    return $this.Exec($arguments).Trim() # remove newline from output
  }
  [void] RemoveNetwork([string]$networkName) {
    $arguments = @("network", "rm", $networkName)
    $this.Exec($arguments)
  }

  [PSObject] InspectNetwork([string]$networkName) {
    $arguments = @("network", "inspect", "--format", "json", $networkName)
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1 # docker network inspect returns an array; take first object
  }
  [void] ConnectNetwork([string]$networkName, [string]$containerName) {
    $arguments = @("network", "connect", $networkName, $containerName)
    $this.Exec($arguments)
  }

  [void] DisconnectNetwork([string]$networkName, [string]$containerName) {
    $arguments = @("network", "disconnect", $networkName, $containerName)
    $this.Exec($arguments)
  }

  [PSObject] SystemInfo() {
    $arguments = @("system", "info", "--format", "json")
    $output = $this.Exec($arguments)
    return $output | ConvertFrom-Json
  }
  hidden static [string] Exec([string]$ClientBinary, [string[]]$arguments) {
    # This could be turned into a global config like in the previous non-static version.
    $DebugPreference = "Continue" # Set to "SilentlyContinue" to hide debug.

    if ($DebugPreference -eq "Continue") {
      Write-Host "Executing: $($ClientBinary) $($arguments -join ' ')" -ForegroundColor DarkGray
    }

    $process = [System.Diagnostics.Process]::Start(
      [System.Diagnostics.ProcessStartInfo]@{
        FileName               = $ClientBinary
        Arguments              = $arguments -join " "
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
        CreateNoWindow         = $true
      }
    )
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
      $stdErr = $process.StandardError.ReadToEnd()
      Write-Error -Message "$($ClientBinary) command failed: $($stdErr)"
      throw "$($ClientBinary) command failed with exit code $($process.ExitCode): $($stdErr)"
    }

    return $process.StandardOutput.ReadToEnd()
  }
  static [string] Run([string]$image, [string[]]$command = @(), [bool]$detach = $false, [string]$name = $null) {
    $arguments = @("run")
    if ($detach) { $arguments += "--detach" }
    if ($name) { $arguments += "--name", $name }
    $arguments += $image
    $arguments += $command
    return [DockerTools]::Exec("docker", $arguments)
  }

  static [PSObject[]] Ps([bool]$all = $false) {
    $arguments = @("ps", "--format", "json")
    if ($all) { $arguments += "-a" }
    return [DockerTools]::Exec("docker", $arguments) | ConvertFrom-Json
  }

  static [void] Stop([string]$containerIdOrName) {
    [DockerTools]::Exec("docker", @("stop", $containerIdOrName))
  }

  static [void] ExecInContainer([string]$containerIdOrName, [string[]]$command, [bool]$interactive = $false, [bool]$tty = $false) {
    $arguments = @("exec")
    if ($interactive) {
      $arguments += "-i"
    }

    if ($tty) {
      $arguments += "-t"
    }
    $arguments += $containerIdOrName
    $arguments += $command
    [void]([DockerTools]::Exec("docker", $arguments))
  }
  static [void] Remove([string]$containerIdOrName, [bool]$force = $false) {
    $arguments = @("rm")
    if ($force) {
      $arguments += "--force"
    }
    $arguments += $containerIdOrName

    [DockerTools]::Exec("docker", $arguments)
  }
  static [string] Logs([string]$containerIdOrName) {
    return [DockerTools]::Exec("docker", @("logs", $containerIdOrName))
  }
  static [PSObject[]] Images() {
    return [DockerTools]::Exec("docker", @("images", "--format", "json")) | ConvertFrom-Json
  }
  static [string] Pull([string]$imageName) {
    return [DockerTools]::Exec("docker", @("pull", $imageName))
  }
  static [void] RemoveImage([string]$imageIdOrName, [bool]$force = $false) {
    $arguments = @("rmi")
    if ($force) {
      $arguments += "--force"
    }
    $arguments += $imageIdOrName
    [DockerTools]::Exec("docker", $arguments)
  }

  static [PSObject] InspectImage([string]$imageIdOrName) {
    $arguments = @("image", "inspect", "--format", "json", $imageIdOrName)
    $output = [DockerTools]::Exec("docker", $arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1
  }
  static [PSObject[]] ListVolumes() {
    $arguments = @("volume", "ls", "--format", "json")
    $output = [DockerTools]::Exec("docker", $arguments)
    return $output | ConvertFrom-Json
  }

  static [string] CreateVolume([string]$volumeName) {
    $arguments = @("volume", "create")
    if ($volumeName) {
      $arguments += $volumeName
    }

    return [DockerTools]::Exec("docker", $arguments).Trim()
  }

  static [void] RemoveVolume([string]$volumeName, [bool]$force = $false) {
    $arguments = @("volume", "rm")
    if ($force) {
      $arguments += "--force"
    }

    $arguments += $volumeName
    [DockerTools]::Exec("docker", $arguments)
  }

  static [PSObject] InspectVolume([string]$volumeName) {
    $arguments = @("volume", "inspect", "--format", "json", $volumeName)
    $output = [DockerTools]::Exec("docker", $arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1
  }
  static [PSObject[]] ListNetworks() {
    return [DockerTools]::Exec("docker", @("network", "ls", "--format", "json")) | ConvertFrom-Json
  }
  static [string] CreateNetwork([string]$networkName, [string]$driver = $null) {
    $arguments = @("network", "create")
    if ($driver) {
      $arguments += "--driver", $driver
    }
    $arguments += $networkName
    return [DockerTools]::Exec("docker", $arguments).Trim()
  }
  static [void] RemoveNetwork([string]$networkName) {
    $arguments = @("network", "rm", $networkName)
    [DockerTools]::Exec("docker", $arguments)
  }
  static [PSObject] InspectNetwork([string]$networkName) {
    $arguments = @("network", "inspect", "--format", "json", $networkName)
    $output = [DockerTools]::Exec("docker", $arguments)
    return $output | ConvertFrom-Json | Select-Object -First 1
  }
  static [void] ConnectNetwork([string]$networkName, [string]$containerName) {
    $arguments = @("network", "connect", $networkName, $containerName)
    [DockerTools]::Exec("docker", $arguments)
  }
  static [void] DisconnectNetwork([string]$networkName, [string]$containerName) {
    $arguments = @("network", "disconnect", $networkName, $containerName)
    [DockerTools]::Exec("docker", $arguments)
  }
  static [PSObject] SystemInfo() {
    $arguments = @("system", "info", "--format", "json")
    $output = [DockerTools]::Exec("docker", $arguments)
    return $output | ConvertFrom-Json
  }
  static [string] BuildxVersion() {
    return [DockerTools]::Exec("docker", @("buildx", "version"))
  }
}
#endregion Classes

# Types that will be available to users when they import the module.
$typestoExport = @(
  [DockerTools]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '

    [System.Management.Automation.ErrorRecord]::new(
      [System.InvalidOperationException]::new($Message),
      'TypeAcceleratorAlreadyExists',
      [System.Management.Automation.ErrorCategory]::InvalidOperation,
      $Type.FullName
    ) | Write-Debug
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
