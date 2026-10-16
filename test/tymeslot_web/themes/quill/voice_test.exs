defmodule TymeslotWeb.Themes.Quill.VoiceTest do
  @moduledoc """
  Quill's voice, polished and calm: so far it words the heading alone, with
  no exclamation mark, and leaves every other line to the shared wording.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Quill.Voice, as: QuillVoice
  alias TymeslotWeb.Themes.Shared.Voice

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  test "is Quill's voice" do
    assert ThemeInfo.get_voice("1") == QuillVoice
  end

  test "words the heading calmly" do
    assert Voice.line(QuillVoice, :heading, %{}, fn -> :shared end) == "Arrange a meeting"
  end

  test "keeps the shared wording for every other line" do
    for key <- Voice.keys() -- [:heading] do
      bindings = Map.new(Voice.bindings(key), &{&1, "Sarah Rodriguez"})

      assert Voice.line(QuillVoice, key, bindings, fn -> :shared end) == :shared,
             "expected #{key} to keep the shared wording"
    end
  end

  test "has no exclamation mark in any line" do
    for key <- Voice.keys() do
      bindings = Map.new(Voice.bindings(key), &{&1, "Sarah Rodriguez"})
      text = QuillVoice.text(key, bindings)
      refute is_binary(text) and String.contains?(text, "!"), "#{key}: #{inspect(text)}"
    end
  end
end
