# The C parser test needs a host C compiler; skip it only where there is none.
exclude = if System.find_executable("cc"), do: [], else: [:requires_cc]
ExUnit.start(exclude: exclude)
