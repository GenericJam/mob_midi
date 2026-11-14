defmodule MobMidiVirtualDeviceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  require Record

  alias Mix.Tasks.MobMidi.Gen.VirtualDevice, as: GenTask
  alias MobMidi.VirtualDevice

  Record.defrecordp(
    :xml_element,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @manifest """
  <?xml version="1.0" encoding="utf-8"?>
  <manifest xmlns:android="http://schemas.android.com/apk/res/android">
      <application android:label="Demo">
          <activity android:name=".MainActivity" android:exported="true" />
      </application>
  </manifest>
  """

  defp cfg!(opts) do
    {:ok, cfg} = VirtualDevice.validate(opts)
    cfg
  end

  # Parses with xmerl and returns {device attrs, [{port tag, port name}]}.
  defp parse_device(xml) do
    {devices, _rest} = xml |> String.to_charlist() |> :xmerl_scan.string(quiet: true)
    assert xml_element(devices, :name) == :devices
    [device] = children(devices)
    assert xml_element(device, :name) == :device
    ports = Enum.map(children(device), &{xml_element(&1, :name), attrs(&1)["name"]})
    {attrs(device), ports}
  end

  defp children(element),
    do: Enum.filter(xml_element(element, :content), &Record.is_record(&1, :xmlElement))

  defp attrs(element) do
    Map.new(xml_element(element, :attributes), fn attr ->
      {Atom.to_string(xml_attribute(attr, :name)), List.to_string(xml_attribute(attr, :value))}
    end)
  end

  describe "validate/1" do
    test "fills defaults" do
      assert VirtualDevice.validate(name: "Humdinger") ==
               {:ok,
                %{
                  name: "Humdinger",
                  manufacturer: "Mob",
                  port_name: "Humdinger",
                  inputs: 0,
                  outputs: 1
                }}

      assert {:ok, %{inputs: 1, outputs: 1}} =
               VirtualDevice.validate(%{name: "Magpie", inputs: 1})
    end

    test "requires a usable name" do
      assert {:error, "name is required"} = VirtualDevice.validate(inputs: 1)
      assert {:error, "name must not be empty"} = VirtualDevice.validate(name: "")
      assert {:error, "name must be a string" <> _} = VirtualDevice.validate(name: :humdinger)

      assert {:error, "name must be at most 64 bytes"} =
               VirtualDevice.validate(name: String.duplicate("a", 65))

      assert {:ok, _} = VirtualDevice.validate(name: String.duplicate("a", 64))

      assert {:error, "name must not contain control" <> _} =
               VirtualDevice.validate(name: "Hum\ndinger")
    end

    test "rejects a device with no ports" do
      assert {:error, "the device needs at least one" <> _} =
               VirtualDevice.validate(name: "Mute", inputs: 0, outputs: 0)
    end

    test "rejects out-of-range and non-integer port counts" do
      assert {:error, "inputs must be between 0 and 16" <> _} =
               VirtualDevice.validate(name: "X", inputs: 17)

      assert {:error, "outputs must be between 0 and 16" <> _} =
               VirtualDevice.validate(name: "X", outputs: -1)

      assert {:error, "inputs must be an integer" <> _} =
               VirtualDevice.validate(name: "X", inputs: "1")

      assert {:ok, %{inputs: 16, outputs: 16}} =
               VirtualDevice.validate(name: "X", inputs: 16, outputs: 16)
    end

    test "rejects bad optional strings, unknown keys and non-options" do
      assert {:error, "manufacturer must be a string" <> _} =
               VirtualDevice.validate(name: "X", manufacturer: 1)

      assert {:error, "port_name must not be empty"} =
               VirtualDevice.validate(name: "X", port_name: "")

      assert {:error, "unknown option(s): :ouputs"} = VirtualDevice.validate(name: "X", ouputs: 1)
      assert {:error, "options must be" <> _} = VirtualDevice.validate("Humdinger")
    end
  end

  describe "device_xml/1" do
    test "Humdinger: one output port, named for exact open_virtual matching" do
      {device, ports} =
        parse_device(VirtualDevice.device_xml(cfg!(name: "Humdinger", inputs: 0, outputs: 1)))

      assert device == %{"manufacturer" => "Mob", "product" => "Humdinger", "name" => "Humdinger"}
      assert ports == [{:"output-port", "Humdinger"}]
    end

    test "Magpie: one input and one output port" do
      {_device, ports} =
        parse_device(VirtualDevice.device_xml(cfg!(name: "Magpie", inputs: 1, outputs: 1)))

      assert ports == [{:"input-port", "Magpie"}, {:"output-port", "Magpie"}]
    end

    test "several ports in a direction are numbered from 1" do
      cfg = cfg!(name: "Rack", inputs: 2, outputs: 3, port_name: "Bus", manufacturer: "Acme")
      {device, ports} = parse_device(VirtualDevice.device_xml(cfg))

      assert device["manufacturer"] == "Acme"

      assert ports == [
               {:"input-port", "Bus 1"},
               {:"input-port", "Bus 2"},
               {:"output-port", "Bus 1"},
               {:"output-port", "Bus 2"},
               {:"output-port", "Bus 3"}
             ]
    end

    test "escapes attribute values" do
      name = ~s(Tom & "Jerry's" <synth>)
      xml = VirtualDevice.device_xml(cfg!(name: name, manufacturer: "A&B"))

      assert xml =~ ~s(product="Tom &amp; &quot;Jerry&apos;s&quot; &lt;synth&gt;")

      assert {%{"product" => ^name, "name" => ^name, "manufacturer" => "A&B"}, [{_, ^name}]} =
               parse_device(xml)
    end
  end

  describe "put_service/2 and remove_service/1" do
    test "inserts the fenced service block before </application>, idempotently" do
      cfg = cfg!(name: "Humdinger")
      {:ok, once} = VirtualDevice.put_service(@manifest, cfg)

      assert once =~
               ~r{android:exported="true" />\n        <!-- mob_midi:virtual-device BEGIN .*-->\n        <!-- MIDI device "Humdinger"}s

      assert once =~ ~r{<!-- mob_midi:virtual-device END -->\n    </application>}
      assert once =~ ~s(android:resource="@xml/mob_midi_device")
      assert VirtualDevice.put_service(once, cfg) == {:ok, once}
      assert {_, []} = once |> String.to_charlist() |> :xmerl_scan.string(quiet: true)
    end

    test "replaces a block generated for a different config" do
      {:ok, humdinger} = VirtualDevice.put_service(@manifest, cfg!(name: "Humdinger"))
      {:ok, magpie} = VirtualDevice.put_service(humdinger, cfg!(name: "Magpie", inputs: 1))

      assert magpie ==
               elem(VirtualDevice.put_service(@manifest, cfg!(name: "Magpie", inputs: 1)), 1)

      assert [_before, _after] = String.split(magpie, "mob_midi:virtual-device BEGIN")
      refute magpie =~ "Humdinger"
    end

    test "handles </application> sharing a line with other content" do
      manifest = ~s(<manifest><application><activity /></application></manifest>)
      {:ok, once} = VirtualDevice.put_service(manifest, cfg!(name: "X"))

      assert once =~ ~r{<activity />\n    <!-- mob_midi:virtual-device BEGIN}
      assert VirtualDevice.put_service(once, cfg!(name: "X")) == {:ok, once}
    end

    test "errors without </application>" do
      assert VirtualDevice.put_service("<manifest />", cfg!(name: "X")) ==
               {:error, "no </application> in the manifest"}
    end

    test "remove_service/1 restores the original manifest" do
      {:ok, with_block} = VirtualDevice.put_service(@manifest, cfg!(name: "Humdinger"))

      assert VirtualDevice.remove_service(with_block) == {:ok, @manifest}
      assert VirtualDevice.remove_service(@manifest) == {:ok, @manifest}
    end

    test "refuses to touch a half-deleted block" do
      {:ok, with_block} = VirtualDevice.put_service(@manifest, cfg!(name: "Humdinger"))
      broken = String.replace(with_block, "<!-- mob_midi:virtual-device END -->", "")

      assert {:error, "unbalanced" <> _} = VirtualDevice.remove_service(broken)

      assert {:error, "unbalanced" <> _} =
               VirtualDevice.put_service(broken, cfg!(name: "Humdinger"))
    end
  end

  describe "mix mob_midi.gen.virtual_device" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_midi_vd_#{System.unique_integer([:positive])}")
      main = Path.join([dir, "app", "src", "main"])
      File.mkdir_p!(main)
      File.write!(Path.join(main, "AndroidManifest.xml"), @manifest)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{
        dir: dir,
        xml: Path.join([main, "res", "xml", "mob_midi_device.xml"]),
        manifest: Path.join(main, "AndroidManifest.xml")
      }
    end

    defp gen(args), do: capture_io(fn -> GenTask.run(args) end)

    test "generates, checks, detects drift and removes", %{dir: dir, xml: xml, manifest: manifest} do
      args = ["--name", "Magpie", "--inputs", "1", "--outputs", "1", "--android-dir", dir]

      assert_raise Mix.Error, ~r/out of date/, fn -> gen(["--check" | args]) end
      gen(args)

      assert File.read!(xml) == VirtualDevice.device_xml(cfg!(name: "Magpie", inputs: 1))

      assert {:ok, File.read!(manifest)} ==
               VirtualDevice.put_service(@manifest, cfg!(name: "Magpie", inputs: 1))

      assert gen(["--check" | args]) =~ "up to date"
      assert gen(args) =~ "unchanged"

      File.write!(xml, String.replace(File.read!(xml), "Magpie", "Magpie2"))
      assert_raise Mix.Error, ~r/mob_midi_device\.xml/, fn -> gen(["--check" | args]) end

      gen(["--remove", "--android-dir", dir])
      refute File.exists?(xml)
      assert File.read!(manifest) == @manifest
      assert gen(["--remove", "--check", "--android-dir", dir]) =~ "up to date"
    end

    test "--check flags a hand-edited manifest block", %{dir: dir, manifest: manifest} do
      args = ["--name", "Humdinger", "--android-dir", dir]
      gen(args)

      File.write!(
        manifest,
        String.replace(File.read!(manifest), ~s(exported="true"), ~s(exported="false"))
      )

      assert_raise Mix.Error, ~r/AndroidManifest\.xml/, fn -> gen(["--check" | args]) end
    end

    test "reads config when --name is absent; flags override it", %{dir: dir, xml: xml} do
      previous = Application.fetch_env(:mob_midi, :virtual_device)

      Application.put_env(:mob_midi, :virtual_device,
        name: "Magpie",
        inputs: 1,
        outputs: 1,
        android_dir: dir
      )

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:mob_midi, :virtual_device, value)
          :error -> Application.delete_env(:mob_midi, :virtual_device)
        end
      end)

      gen(["--outputs", "2"])

      assert File.read!(xml) ==
               VirtualDevice.device_xml(cfg!(name: "Magpie", inputs: 1, outputs: 2))
    end

    test "rejects invalid configs and bad arguments", %{dir: dir} do
      assert_raise Mix.Error, ~r/needs at least one/, fn ->
        gen(["--name", "X", "--outputs", "0", "--android-dir", dir])
      end

      assert_raise Mix.Error, ~r/invalid arguments/, fn -> gen(["--name", "X", "--bogus"]) end

      assert_raise Mix.Error, ~r/AndroidManifest\.xml/, fn ->
        gen(["--name", "X", "--android-dir", Path.join(dir, "nope")])
      end
    end
  end
end
