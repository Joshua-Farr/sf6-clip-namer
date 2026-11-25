-- win_silent.lua
-- Windows helpers that never flash a console window.
-- Uses LuaJIT FFI (bundled with OBS) for CreateProcess / filesystem APIs.

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
if not bit_ok then
  bit = bit32
end

local kernel32 = nil
local shell32 = nil
local ready = false

local FILE_ATTRIBUTE_DIRECTORY = 0x00000010
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local CREATE_NO_WINDOW = 0x08000000
local STARTF_USESHOWWINDOW = 0x00000001
local SW_HIDE = 0
local ERROR_ALREADY_EXISTS = 183
local ERROR_FILE_EXISTS = 80
local CP_UTF8 = 65001

local function init_ffi()
  if ready then
    return true
  end
  if not ffi_ok or not ffi then
    return false
  end

  local ok = pcall(function()
    ffi.cdef[[
      typedef unsigned short wchar_t;
      typedef void* HANDLE;
      typedef void* HWND;
      typedef unsigned long DWORD;
      typedef int BOOL;
      typedef const char* LPCSTR;
      typedef char* LPSTR;
      typedef const wchar_t* LPCWSTR;
      typedef wchar_t* LPWSTR;
      typedef void* LPVOID;
      typedef unsigned short WORD;
      typedef unsigned char BYTE;

      typedef struct _SECURITY_ATTRIBUTES {
        DWORD nLength;
        LPVOID lpSecurityDescriptor;
        BOOL bInheritHandle;
      } SECURITY_ATTRIBUTES;

      typedef struct _STARTUPINFOW {
        DWORD cb;
        LPWSTR lpReserved;
        LPWSTR lpDesktop;
        LPWSTR lpTitle;
        DWORD dwX;
        DWORD dwY;
        DWORD dwXSize;
        DWORD dwYSize;
        DWORD dwXCountChars;
        DWORD dwYCountChars;
        DWORD dwFillAttribute;
        DWORD dwFlags;
        WORD wShowWindow;
        WORD cbReserved2;
        BYTE* lpReserved2;
        HANDLE hStdInput;
        HANDLE hStdOutput;
        HANDLE hStdError;
      } STARTUPINFOW;

      typedef struct _PROCESS_INFORMATION {
        HANDLE hProcess;
        HANDLE hThread;
        DWORD dwProcessId;
        DWORD dwThreadId;
      } PROCESS_INFORMATION;

      int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags,
        LPCSTR lpMultiByteStr, int cbMultiByte,
        LPWSTR lpWideCharStr, int cchWideChar);

      DWORD GetFileAttributesW(LPCWSTR lpFileName);
      BOOL CreateDirectoryW(LPCWSTR lpPathName, SECURITY_ATTRIBUTES* lpSecurityAttributes);
      int SHCreateDirectoryExW(HWND hwnd, LPCWSTR pszPath, SECURITY_ATTRIBUTES* psa);

      BOOL CreateProcessW(
        LPCWSTR lpApplicationName,
        LPWSTR lpCommandLine,
        SECURITY_ATTRIBUTES* lpProcessAttributes,
        SECURITY_ATTRIBUTES* lpThreadAttributes,
        BOOL bInheritHandles,
        DWORD dwCreationFlags,
        LPVOID lpEnvironment,
        LPCWSTR lpCurrentDirectory,
        STARTUPINFOW* lpStartupInfo,
        PROCESS_INFORMATION* lpProcessInformation);

      BOOL CloseHandle(HANDLE hObject);
    ]]
    kernel32 = ffi.load("kernel32")
    shell32 = ffi.load("shell32")
  end)

  if not ok then
    return false
  end

  -- Declared separately so duplicate typedefs from other modules don't
  -- prevent registering the wait helpers.
  pcall(function()
    ffi.cdef[[
      DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
      BOOL GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
    ]]
  end)

  ready = true
  return true
end

--- Convert UTF-8 to a mutable wchar buffer (nul-terminated). Returns buf, length.
local function to_wide(str)
  str = tostring(str or "")
  local needed = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, #str, nil, 0)
  if needed <= 0 then
    return nil, 0
  end
  local buf = ffi.new("wchar_t[?]", needed + 1)
  kernel32.MultiByteToWideChar(CP_UTF8, 0, str, #str, buf, needed)
  buf[needed] = 0
  return buf, needed
end

local function normalize_dir(path)
  if not path or path == "" then
    return ""
  end
  return path:gsub("/", "\\"):gsub("[\\/]+$", "")
end

function M.available()
  return init_ffi()
end

--- True if path exists and is a directory.
function M.dir_exists(path)
  local p = normalize_dir(path)
  if p == "" then
    return false
  end
  if init_ffi() then
    local w = to_wide(p)
    if not w then
      return false
    end
    local attrs = tonumber(kernel32.GetFileAttributesW(w))
    if not attrs or attrs == INVALID_FILE_ATTRIBUTES or attrs == -1 then
      return false
    end
    if not bit or not bit.band then
      return (attrs % (FILE_ATTRIBUTE_DIRECTORY * 2)) >= FILE_ATTRIBUTE_DIRECTORY
    end
    return bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
  end
  -- Fallback without shell: try creating a probe file inside the directory.
  local probe = p .. "\\.sf6_dir_probe"
  local f = io.open(probe, "w")
  if f then
    f:close()
    os.remove(probe)
    return true
  end
  return false
end

--- Create directory and parents. Returns ok, err.
function M.ensure_dir(path)
  local p = normalize_dir(path)
  if p == "" then
    return false, "missing directory path"
  end
  if M.dir_exists(p) then
    return true, nil
  end
  if init_ffi() then
    local w = to_wide(p)
    if not w then
      return false, "invalid directory path"
    end
    local rc = tonumber(shell32.SHCreateDirectoryExW(nil, w, nil)) or -1
    if rc == 0 or rc == ERROR_ALREADY_EXISTS or rc == ERROR_FILE_EXISTS then
      if M.dir_exists(p) then
        return true, nil
      end
    end
    -- Fallback: create segment by segment with CreateDirectoryW
    local prefix = ""
    local first = true
    for part in p:gmatch("[^\\]+") do
      if first and part:match("^%a:$") then
        prefix = part
        first = false
      else
        if prefix == "" then
          prefix = part
        else
          prefix = prefix .. "\\" .. part
        end
        first = false
        if not M.dir_exists(prefix) then
          local ww = to_wide(prefix)
          if ww then
            kernel32.CreateDirectoryW(ww, nil)
          end
        end
      end
    end
    if M.dir_exists(p) then
      return true, nil
    end
    return false, "failed to create directory: " .. p
  end
  return false, "silent Win32 APIs unavailable"
end

local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT = 0x00000102
local INFINITE = 0xFFFFFFFF

--- Start a process with no console window. cmdline is a full command line string.
--- Returns true if CreateProcess succeeded (does not wait).
function M.run_hidden(cmdline)
  local ok = M.run_hidden_wait(cmdline, 0)
  return ok == true
end

--- Start a hidden process and optionally wait.
--- timeout_ms:
---   nil / omitted → fire-and-forget (same as run_hidden)
---   0 → return immediately after spawn (do not wait)
---   >0 → wait up to that many ms
--- Returns: ok, err_or_exit_code
---   ok=true, exit_code on success (exit_code may be nil if not waited)
---   ok=false, reason string on failure / timeout
function M.run_hidden_wait(cmdline, timeout_ms)
  if not cmdline or cmdline == "" then
    return false, "missing cmdline"
  end
  if not init_ffi() then
    return false, "silent Win32 APIs unavailable"
  end

  local mutable = to_wide(cmdline)
  if not mutable then
    return false, "invalid cmdline"
  end

  local si = ffi.new("STARTUPINFOW")
  si.cb = ffi.sizeof(si)
  si.dwFlags = STARTF_USESHOWWINDOW
  si.wShowWindow = SW_HIDE

  local pi = ffi.new("PROCESS_INFORMATION")
  local ok = kernel32.CreateProcessW(
    nil,
    mutable,
    nil,
    nil,
    0,
    CREATE_NO_WINDOW,
    nil,
    nil,
    si,
    pi
  )
  if ok == 0 then
    return false, "CreateProcess failed"
  end

  kernel32.CloseHandle(pi.hThread)

  if timeout_ms == nil or timeout_ms == 0 then
    kernel32.CloseHandle(pi.hProcess)
    return true, nil
  end

  local wait_ms = tonumber(timeout_ms) or 0
  if wait_ms < 0 then
    wait_ms = INFINITE
  end
  local waited = tonumber(kernel32.WaitForSingleObject(pi.hProcess, wait_ms)) or -1
  if waited == WAIT_TIMEOUT then
    kernel32.CloseHandle(pi.hProcess)
    return false, "timeout"
  end
  if waited ~= WAIT_OBJECT_0 then
    kernel32.CloseHandle(pi.hProcess)
    return false, "wait failed"
  end

  local code = ffi.new("DWORD[1]")
  kernel32.GetExitCodeProcess(pi.hProcess, code)
  kernel32.CloseHandle(pi.hProcess)
  return true, tonumber(code[0])
end

return M
