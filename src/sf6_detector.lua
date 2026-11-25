-- sf6_detector.lua
-- Detect whether Street Fighter 6 (StreetFighter6.exe) is running on Windows.
-- Uses Win32 Toolhelp via LuaJIT FFI so we never spawn a console (no tasklist).

local M = {}

local PROCESS_NAME = "StreetFighter6.exe"
local TH32CS_SNAPPROCESS = 0x00000002

local ffi_ok, ffi = pcall(require, "ffi")
local kernel32 = nil

if ffi_ok then
  pcall(function()
    ffi.cdef[[
      typedef void* HANDLE;
      typedef unsigned long DWORD;
      typedef long LONG;
      typedef uintptr_t ULONG_PTR;
      typedef int BOOL;

      typedef struct {
        DWORD dwSize;
        DWORD cntUsage;
        DWORD th32ProcessID;
        ULONG_PTR th32DefaultHeapID;
        DWORD th32ModuleID;
        DWORD cntThreads;
        DWORD th32ParentProcessID;
        LONG pcPriClassBase;
        DWORD dwFlags;
        char szExeFile[260];
      } PROCESSENTRY32;

      HANDLE __stdcall CreateToolhelp32Snapshot(DWORD dwFlags, DWORD th32ProcessID);
      BOOL __stdcall Process32First(HANDLE hSnapshot, PROCESSENTRY32 *lppe);
      BOOL __stdcall Process32Next(HANDLE hSnapshot, PROCESSENTRY32 *lppe);
      BOOL __stdcall CloseHandle(HANDLE hObject);
    ]]
    kernel32 = ffi.load("kernel32")
  end)
end

function M.process_name()
  return PROCESS_NAME
end

local function equals_ignore_case(a, b)
  return a:lower() == b:lower()
end

--- Returns true if StreetFighter6.exe is running (no console windows).
--- Optional override: is_running(check_fn) where check_fn() -> boolean
function M.is_running(check_fn)
  if check_fn then
    local ok, result = pcall(check_fn)
    return ok and result == true
  end

  if not kernel32 then
    return false
  end

  local snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
  if snapshot == nil or snapshot == ffi.cast("HANDLE", -1) then
    return false
  end

  local entry = ffi.new("PROCESSENTRY32")
  entry.dwSize = ffi.sizeof(entry)

  local found = false
  if kernel32.Process32First(snapshot, entry) ~= 0 then
    repeat
      local name = ffi.string(entry.szExeFile)
      if equals_ignore_case(name, PROCESS_NAME) then
        found = true
        break
      end
    until kernel32.Process32Next(snapshot, entry) == 0
  end

  kernel32.CloseHandle(snapshot)
  return found
end

return M
