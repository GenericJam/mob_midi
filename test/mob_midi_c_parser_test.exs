defmodule MobMidi.CParserTest do
  # Compiles and runs the host C tests: test/c/mob_midi_parser_test.c against
  # priv/include/mob_midi_parser.h, and test/c/mob_midi_queue_test.c against
  # priv/native/android/mob_midi_queue.h (the Android send queue's
  # back-pressure: refuse until drained, discard, generations).
  # test_helper.exs excludes :requires_cc when there is no `cc` on the PATH.
  use ExUnit.Case, async: true

  @moduletag :requires_cc

  @root Path.expand("..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_midi_c_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the C parser passes its host test", %{dir: dir} do
    {out, status} = run_c_test(dir, "mob_midi_parser_test", "priv/include")
    assert status == 0, "C parser test failed:\n" <> out
  end

  test "the send queue passes its host test", %{dir: dir} do
    {out, status} = run_c_test(dir, "mob_midi_queue_test", "priv/native/android")
    assert status == 0, "send queue test failed:\n" <> out
  end

  # Compiles test/c/<name>.c (cc must succeed) and runs it: {output, exit status}.
  defp run_c_test(dir, name, include) do
    bin = Path.join(dir, name)

    args =
      ~w(-std=c99 -Wall -Wextra -Werror -pedantic) ++
        ["-I", Path.join(@root, include), Path.join(@root, "test/c/#{name}.c"), "-o", bin]

    {out, status} = System.cmd(System.find_executable("cc"), args, stderr_to_stdout: true)
    assert status == 0, "cc failed:\n" <> out

    System.cmd(bin, [], stderr_to_stdout: true)
  end
end
