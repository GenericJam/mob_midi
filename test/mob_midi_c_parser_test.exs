defmodule MobMidi.CParserTest do
  # Compiles and runs test/c/mob_midi_parser_test.c against
  # priv/include/mob_midi_parser.h. test_helper.exs excludes :requires_cc when
  # there is no `cc` on the PATH.
  use ExUnit.Case, async: true

  @moduletag :requires_cc

  @root Path.expand("..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_midi_c_parser_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{bin: Path.join(dir, "mob_midi_parser_test")}
  end

  test "the C parser passes its host test", %{bin: bin} do
    cc = System.find_executable("cc")

    args =
      ~w(-std=c99 -Wall -Wextra -Werror -pedantic) ++
        [
          "-I",
          Path.join(@root, "priv/include"),
          Path.join(@root, "test/c/mob_midi_parser_test.c"),
          "-o",
          bin
        ]

    {out, status} = System.cmd(cc, args, stderr_to_stdout: true)
    assert status == 0, "cc failed:\n" <> out

    {out, status} = System.cmd(bin, [], stderr_to_stdout: true)
    assert status == 0, "C parser test failed:\n" <> out
  end
end
