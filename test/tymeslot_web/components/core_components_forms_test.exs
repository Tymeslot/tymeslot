defmodule TymeslotWeb.Components.CoreComponentsFormsTest do
  use ExUnit.Case, async: true

  @moduletag :components

  alias Gettext.Plural
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Gettext, as: Backend

  describe "translate_error/1 with a {msg, opts} changeset error tuple" do
    test "routes through gettext instead of returning the raw English msgid unconditionally" do
      # "something_went_wrong" already carries a real German translation in the
      # `errors` domain (priv/gettext/de/LC_MESSAGES/errors.po), so this proves
      # translate_error/1 actually calls gettext rather than merely doing the
      # old string-replace-on-the-msgid.
      german =
        Gettext.with_locale(Backend, "de", fn ->
          Forms.translate_error({"something_went_wrong", []})
        end)

      english =
        Gettext.with_locale(Backend, "en", fn ->
          Forms.translate_error({"something_went_wrong", []})
        end)

      assert german == "Ein Fehler ist aufgetreten"
      assert english == "Something went wrong"
      assert german != english
    end

    test "interpolates non-count bindings the same way Gettext.dgettext/4 would" do
      assigns = [number: 10]

      Enum.each(["en", "de"], fn locale ->
        Gettext.with_locale(Backend, locale, fn ->
          expected = Gettext.dgettext(Backend, "errors", "must be less than %{number}", assigns)
          assert Forms.translate_error({"must be less than %{number}", assigns}) == expected
        end)
      end)
    end
  end

  describe "translate_error/1 with a count-based (pluralised) error tuple" do
    test "delegates to Gettext.dngettext/6 with matching msgid/msgid_plural, count, and bindings" do
      msg = "should be at least %{count} character(s)"

      for count <- [1, 5] do
        opts = [count: count, validation: :length, kind: :min, type: :string]

        Enum.each(["en", "de"], fn locale ->
          Gettext.with_locale(Backend, locale, fn ->
            expected = Gettext.dngettext(Backend, "errors", msg, msg, count, opts)
            assert Forms.translate_error({msg, opts}) == expected
          end)
        end)
      end
    end

    test "the errors domain's German plural rule selects a different form for count: 1 vs count: 5" do
      # `should be at least %{count} character(s)` has not been through the
      # central German translation pass yet, so its msgstr[0]/msgstr[1] are
      # still empty and both counts render the same (untranslated) English
      # text. What must already be correct — independently of that pending
      # translation — is which plural bucket German selects for each count,
      # since that is what `Gettext.dngettext/6` relies on inside
      # `translate_error/1`. German uses the same two-bucket rule as English.
      assert Plural.plural("de", 1) == 0
      assert Plural.plural("de", 5) == 1
    end
  end

  describe "translate_error/1 with non-tuple input" do
    test "returns a plain binary message unchanged" do
      assert Forms.translate_error("plain message") == "plain message"
    end

    test "inspects anything else" do
      assert Forms.translate_error(:some_atom) == ":some_atom"
    end
  end
end
