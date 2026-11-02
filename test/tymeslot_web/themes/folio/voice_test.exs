defmodule TymeslotWeb.Themes.Folio.VoiceTest do
  @moduledoc """
  Folio's personal voice: the shared booking lines it words, in the spec's
  sample lines, no instruction label, and the shared wording for the rest.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Folio.Voice, as: FolioVoice
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.Voice

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp shared, do: :shared

  test "is Folio's voice" do
    assert ThemeInfo.get_voice("4") == FolioVoice
  end

  test "says the spec's personal lines" do
    assert Voice.line(FolioVoice, :heading, %{}, &shared/0) == "Ways to work with me"
    assert Voice.line(FolioVoice, :submit, %{}, &shared/0) == "Book our session"
    assert Voice.line(FolioVoice, :submit_request, %{}, &shared/0) == "Request this time"

    assert Voice.line(FolioVoice, :slot_taken, %{}, &shared/0) ==
             "Someone took that time a moment ago. Here are the nearest ones."
  end

  test "gives no instruction label" do
    assert Voice.line(FolioVoice, :instruction, %{}, &shared/0) == ""
  end

  test "keeps the shared wording for the lines it leaves alone" do
    worded = [:heading, :instruction, :submit, :submit_request, :slot_taken]

    for key <- Voice.keys() -- worded do
      bindings = Map.new(Voice.bindings(key), &{&1, "Mia Laurent"})

      assert Voice.line(FolioVoice, key, bindings, &shared/0) == :shared,
             "expected #{key} to keep the shared wording"
    end
  end

  test "names the payment on a paid type, never the session" do
    paid = %{requires_approval: false, payment_required: true}

    assert BookingLabels.submit_label(false, paid, "Submit", :folio) ==
             "Continue to payment"
  end

  test "never says slot or meeting type" do
    for key <- Voice.keys() do
      bindings = Map.new(Voice.bindings(key), &{&1, "Mia Laurent"})
      text = FolioVoice.text(key, bindings)

      refute is_binary(text) and text =~ ~r/\bslot\b|meeting type/i,
             "#{key}: #{inspect(text)}"
    end
  end
end
