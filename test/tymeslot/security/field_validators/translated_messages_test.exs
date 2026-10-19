defmodule Tymeslot.Security.FieldValidators.TranslatedMessagesTest do
  @moduledoc """
  Field validator messages reach sign-up, sign-in, booking and contact forms
  unchanged, so they are translated into the visitor's language like the rest
  of the form.
  """
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :i18n

  alias Tymeslot.Auth
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.FieldValidators.NameValidator
  alias Tymeslot.Security.FieldValidators.TLDList
  alias Tymeslot.Security.UniversalSanitizer

  defp in_locale(locale, fun), do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)

  test "an email validation message is in the current language" do
    assert {:error, "E-Mail ist erforderlich"} =
             in_locale("de", fn -> EmailValidator.validate("") end)

    assert {:error, "Email is required"} = in_locale("en", fn -> EmailValidator.validate("") end)
  end

  test "the auth API returns the translated message it documents" do
    assert {:error, message} = in_locale("de", fn -> Auth.validate_email("") end)
    assert message == "E-Mail ist erforderlich"
  end

  test "an interpolated limit survives translation" do
    assert {:error, message} =
             in_locale("uk", fn -> NameValidator.validate("A", min_length: 2) end)

    assert message == "Ім'я закоротке (мінімальна кількість символів: 2)"
  end

  test "a domain ending suggestion is translated with both endings" do
    assert {:error, message} = in_locale("de", fn -> TLDList.validate_tld("con", "Email") end)
    assert message == "E-Mail hat eine unbekannte Endung (.con). Meinten Sie .com?"
  end

  test "a sanitiser limit is translated" do
    assert {:error, message} =
             in_locale("de", fn ->
               UniversalSanitizer.sanitize_and_validate(String.duplicate("a", 20),
                 max_length: 5
               )
             end)

    refute message =~ "Input exceeds"
    assert message =~ "5"
  end
end
