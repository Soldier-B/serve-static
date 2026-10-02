# Serve-Static.ps1

A simple PowerShell script to serve static files temporarily.

## Global Configuration

You can run the script locally (`.\Serve-Static.ps1`) or configure it for global access using one of these methods:

* **Add to your PATH:** Add the folder containing the script to your system's `PATH` environment variable.
* **Profile Function:** Add a wrapper function to your PowerShell profile (`notepad $PROFILE`) to cleanly pass arguments:
  ```powershell
  function Serve-Static {
      & "C:\path\to\Serve-Static.ps1" @args
  }

  ```

* **Profile Alias:** Map a shortcut name in your PowerShell profile (`notepad $PROFILE`):
  ```powershell
  Set-Alias -Name Serve-Static -Value "C:\path\to\Serve-Static.ps1"
  ```

## Example Usage

* `Serve-Static` *(or `.\Serve-Static.ps1`)*
* `Serve-Static -Path C:\site -Port 3000 -Open`


> Note: If you get an execution policy error open an admin terminal and run:
> ```powershell
> Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```
