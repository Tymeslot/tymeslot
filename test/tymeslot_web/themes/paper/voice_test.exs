defmodule TymeslotWeb.Themes.Paper.VoiceTest do
  @moduledoc """
  Paper's neutral voice: the shared booking lines it words, in the spec's
  sample lines, no greeting, and the shared wording for every other line.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Paper.Voice, as: PaperVoice
  alias TymeslotWeb.Themes.Shared.Voice

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  # credo:disable-for-next-line CredoChecks.ThinWrapperFunctions
  defp line(key, bindings \\ %{}), do: Voice.line(PaperVoice, key, bindings, fn -> :shared end)

  test "is Paper's voice" do
    assert ThemeInfo.get_voice("3") == PaperVoice
  end

  test "says the spec's neutral lines" do
    assert line(:heading_named, %{name: "Ana Silva"}) == "Book a meeting with Ana Silva"
    assert line(:heading) == "Book a meeting"
    assert line(:instruction) == "Select a meeting type"
    assert line(:submit) == "Confirm booking"
    assert line(:slot_taken) == "That time was just booked. Choose another."
  end

  test "greets nobody" do
    assert line(:greeting, %{name: "Ana Silva"}) == ""
  end

  test "keeps the shared wording for the lines it leaves alone" do
    for key <-
          Voice.keys() --
            [:heading, :heading_named, :greeting, :instruction, :submit, :slot_taken] do
      bindings = Map.new(Voice.bindings(key), &{&1, "Ana Silva"})
      assert line(key, bindings) == :shared, "expected #{key} to keep the shared wording"
    end
  end

  test "has no exclamation mark in any line" do
    for key <- Voice.keys() do
      bindings = Map.new(Voice.bindings(key), &{&1, "Ana Silva"})
      text = PaperVoice.text(key, bindings)
      refute is_binary(text) and String.contains?(text, "!"), "#{key}: #{inspect(text)}"
    end
  end
end
