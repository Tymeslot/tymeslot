defmodule TymeslotWeb.Themes.Shared.VoiceTest do
  @moduledoc """
  A theme's voice words the shared booking lines its own way: asked first,
  with the shared wording kept for every line it leaves alone, and only for
  the closed set of lines the shared modules produce.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Test.FixtureTheme.Voice, as: FixtureVoice
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Shared.Voice
  alias TymeslotWeb.ThemeTestMatrix

  defmodule Probe do
    @moduledoc false
    @behaviour TymeslotWeb.Themes.Shared.Voice

    @impl TymeslotWeb.Themes.Shared.Voice
    def text(:submit, _bindings), do: "Go"
    def text(:greeting, %{name: name}), do: "Yo, " <> name
    def text(_key, _bindings), do: nil
  end

  defp shared, do: fn -> "shared wording" end

  describe "line/4" do
    test "is the voice's wording when it has one for the key" do
      assert Voice.line(Probe, :submit, %{}, shared()) == "Go"
      assert Voice.line(Probe, :greeting, %{name: "Sam"}, shared()) == "Yo, Sam"
    end

    test "is the shared wording for a key the voice leaves alone" do
      assert Voice.line(Probe, :instruction, %{}, shared()) == "shared wording"
    end

    test "is the shared wording without a voice" do
      assert Voice.line(nil, :submit, %{}, shared()) == "shared wording"
    end

    test "refuses a key outside the closed set, with or without a voice" do
      assert_raise ArgumentError, ~r/:tagline/, fn ->
        Voice.line(Probe, :tagline, %{}, shared())
      end

      assert_raise ArgumentError, ~r/:tagline/, fn ->
        Voice.line(nil, :tagline, %{}, shared())
      end
    end
  end

  describe "of/1" do
    test "is the voice a theme names" do
      assert Voice.of(:fixture) == FixtureVoice
    end

    test "is nil for a theme with no voice, an unknown key and no key" do
      assert Voice.of(:quill) == nil
      assert Voice.of(:showcase) == nil
      assert Voice.of(:some_future_theme) == nil
      assert Voice.of(nil) == nil
    end
  end

  describe "the registered themes' voices" do
    # A line that used a binding its key does not provide would raise only
    # on the page, in the one locale and the one state that reaches it.
    test "answer every key, given its bindings, with a line or nil" do
      voices = registered_voices()
      assert voices != []

      answers =
        for voice <- voices, key <- Voice.keys() do
          {voice, key, voice.text(key, bindings_for(key))}
        end

      assert Enum.reject(answers, fn {_voice, _key, text} ->
               is_nil(text) or (is_binary(text) and not String.contains?(text, "%{"))
             end) == []
    end

    test "each words at least one line, so naming one is never a no-op" do
      voices = registered_voices()
      assert voices != []

      silent =
        Enum.reject(voices, fn voice ->
          Enum.any?(Voice.keys(), &(voice.text(&1, bindings_for(&1)) != nil))
        end)

      assert silent == []
    end
  end

  defp registered_voices do
    ThemeTestMatrix.registered_ids()
    |> Enum.map(&ThemeInfo.get_voice/1)
    |> Enum.reject(&is_nil/1)
  end

  defp bindings_for(key), do: Map.new(Voice.bindings(key), &{&1, "Sam"})
end
