defmodule Mix.Tasks.MobMidi.Gen.VirtualDevice do
  @shortdoc "Declares the app's own Android MIDI device (manifest + res/xml)"

  @moduledoc """
  Generates the Android declaration of the app's own MIDI device — the one
  other apps play into or listen to.

  Android reads a `MidiDeviceService`'s name and ports from the host app's
  manifest and a `res/xml` file, so they can't ship inside the plugin. This
  task writes:

    * `<android-dir>/app/src/main/res/xml/mob_midi_device.xml` — the device
      name and ports;
    * a fenced `<service>` block for `io.mob.midi.MobMidiDeviceService` just
      before `</application>` in `<android-dir>/app/src/main/AndroidManifest.xml`.

  Re-running replaces both, so it's safe to run after every config change.

  ## Examples

  A source other apps listen to (no input, one output):

      mix mob_midi.gen.virtual_device --name Humdinger --inputs 0 --outputs 1

  A device other apps both play into and listen to:

      mix mob_midi.gen.virtual_device --name Magpie --inputs 1 --outputs 1

  An `<input-port>` is one other apps send into (the app receives); an
  `<output-port>` is one the app sends out of. The app then opens the device
  with `MobMidi.open_virtual(socket, "Humdinger")` — the name must match.

  ## Options

    * `--name` — device name (required unless configured), at most 64 bytes
    * `--inputs` — input ports, 0..16 (default 0)
    * `--outputs` — output ports, 0..16 (default 1)
    * `--manufacturer` — manufacturer shown by MIDI apps (default `Mob`)
    * `--port-name` — port name (default the device name; numbered
      `"<name> 1"`, `"<name> 2"`, … when a direction has several ports)
    * `--android-dir` — the host's Android project (default `android`)
    * `--check` — write nothing; fail if the files differ from what would be
      generated (for CI)
    * `--remove` — delete the res/xml file and the manifest block

  ## Configuration

  Without `--name`, options come from the application config, and any flags
  given override them:

      config :mob_midi, :virtual_device,
        name: "Magpie",
        inputs: 1,
        outputs: 1

  `android_dir:` is accepted there too.
  """

  use Mix.Task

  alias MobMidi.VirtualDevice

  @switches [
    name: :string,
    inputs: :integer,
    outputs: :integer,
    manufacturer: :string,
    port_name: :string,
    android_dir: :string,
    check: :boolean,
    remove: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {flags, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")
    end

    Mix.Task.run("loadconfig")

    {check?, flags} = Keyword.pop(flags, :check, false)
    {remove?, flags} = Keyword.pop(flags, :remove, false)
    {android_dir, opts} = Keyword.pop(options(flags), :android_dir, "android")

    paths = paths(android_dir)
    plan = plan(paths, opts, remove?)

    if check?, do: check(plan), else: apply_plan(plan)
  end

  defp options(flags) do
    base =
      if Keyword.has_key?(flags, :name),
        do: [],
        else: Application.get_env(:mob_midi, :virtual_device, [])

    Keyword.merge(base, flags)
  end

  defp paths(android_dir) do
    main = Path.join([android_dir, "app", "src", "main"])

    %{
      xml: Path.join([main, "res", "xml", VirtualDevice.resource_name() <> ".xml"]),
      manifest: Path.join(main, "AndroidManifest.xml")
    }
  end

  # Each entry is {path, desired content | :absent}; --check and the write
  # path both work off this, so they can't disagree.
  defp plan(paths, _opts, true = _remove?) do
    manifest = read_manifest!(paths.manifest)
    [{paths.xml, :absent}, {paths.manifest, ok!(VirtualDevice.remove_service(manifest))}]
  end

  defp plan(paths, opts, false = _remove?) do
    cfg = ok!(VirtualDevice.validate(opts))
    manifest = read_manifest!(paths.manifest)

    [
      {paths.xml, VirtualDevice.device_xml(cfg)},
      {paths.manifest, ok!(VirtualDevice.put_service(manifest, cfg))}
    ]
  end

  defp read_manifest!(path) do
    case File.read(path) do
      {:ok, xml} ->
        xml

      {:error, reason} ->
        Mix.raise("can't read #{path} (#{:file.format_error(reason)}); pass --android-dir")
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise("mob_midi.gen.virtual_device: #{message}")

  defp check(plan) do
    case Enum.reject(plan, &current?/1) do
      [] ->
        Mix.shell().info("mob_midi virtual device declaration is up to date")

      stale ->
        Mix.raise(
          "mob_midi virtual device declaration is out of date: " <>
            Enum.map_join(stale, ", ", &elem(&1, 0)) <>
            "; run mix mob_midi.gen.virtual_device"
        )
    end
  end

  defp current?({path, :absent}), do: not File.exists?(path)
  defp current?({path, content}), do: File.read(path) == {:ok, content}

  defp apply_plan(plan) do
    Enum.each(plan, fn entry ->
      if current?(entry), do: Mix.shell().info("unchanged #{elem(entry, 0)}"), else: write(entry)
    end)
  end

  defp write({path, :absent}) do
    File.rm!(path)
    Mix.shell().info("removed #{path}")
  end

  defp write({path, content}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    Mix.shell().info("wrote #{path}")
  end
end
