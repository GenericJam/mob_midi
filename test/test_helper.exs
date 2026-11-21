# The C tests need a host C compiler; skip them only where there is none. The
# iOS NIF's host test (CoreMIDI) runs only on macOS.
exclude = if System.find_executable("cc"), do: [], else: [:requires_cc]
exclude = if :os.type() == {:unix, :darwin}, do: exclude, else: [:macos_only | exclude]
ExUnit.start(exclude: exclude)
