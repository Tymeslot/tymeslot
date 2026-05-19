defmodule Tymeslot.Security.FieldValidators.UrlValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.UrlValidator

  describe "validate/2" do
    test "https URL ok", do: assert(:ok = UrlValidator.validate("https://example.com"))
    test "http URL ok", do: assert(:ok = UrlValidator.validate("http://example.com/path?q=1"))

    test "rejects javascript:",
      do: assert({:error, _} = UrlValidator.validate("javascript:alert(1)"))

    test "rejects no scheme", do: assert({:error, _} = UrlValidator.validate("example.com"))

    test "blank required fails",
      do: assert({:error, _} = UrlValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = UrlValidator.validate("", required: false))

    test "nil required fails",
      do: assert({:error, _} = UrlValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = UrlValidator.validate(nil, required: false))
  end
end
