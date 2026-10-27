defmodule Tymeslot.Auth.RegistrationTermsLocaleTest do
  # Changes the application-wide :enforce_legal_agreements flag.
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth.Registration
  alias TymeslotWeb.Helpers.ClientIP

  setup do
    previous = Application.get_env(:tymeslot, :enforce_legal_agreements)
    Application.put_env(:tymeslot, :enforce_legal_agreements, true)
    on_exit(fn -> Application.put_env(:tymeslot, :enforce_legal_agreements, previous) end)
  end

  # The refusal reaches the sign-up form in the visitor's language, with no
  # field name made up in English in front of it.
  test "refuses unaccepted terms in the visitor's language" do
    params = %{
      "email" => "terms@example.com",
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "name" => "New User"
    }

    assert {:error, :input, message} =
             Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
               Registration.register_user(params, ClientIP.request_opts(%Plug.Conn{}))
             end)

    assert message ==
             "Bitte korrigieren Sie die folgenden Fehler: Die Nutzungsbedingungen müssen akzeptiert werden"
  end
end
