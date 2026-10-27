defmodule Tymeslot.Auth.ErrorFormatterTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth.ErrorFormatter

  defmodule Item do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :title, :string
    end

    @spec changeset(%__MODULE__{}, map()) :: Changeset.t()
    def changeset(item, attrs),
      do: item |> Changeset.cast(attrs, [:title]) |> Changeset.validate_required([:title])
  end

  defmodule Parent do
    use Ecto.Schema

    embedded_schema do
      embeds_many :items, Item
    end
  end

  describe "format_auth_error/1" do
    test "answers every failed-credentials reason with one generic message" do
      for reason <- [:not_found, :invalid_password] do
        assert ErrorFormatter.format_auth_error(reason) ==
                 "Invalid email or password. If you signed up recently, check your inbox for the verification link."
      end
    end

    test "names the social login for an account without a password" do
      assert ErrorFormatter.format_auth_error(:oauth_user) =~ "associated with a social login"
    end

    test "formats the rate limit and the closed-flow reasons" do
      assert ErrorFormatter.format_auth_error(:rate_limited) ==
               "Too many attempts. Please try again later."

      assert ErrorFormatter.format_auth_error(:registration_disabled) ==
               "Registration is currently disabled."

      assert ErrorFormatter.format_auth_error(:password_auth_disabled) ==
               "Password authentication is currently disabled."
    end

    test "falls back to a generic message" do
      assert ErrorFormatter.format_auth_error(:unknown_reason) ==
               "An error occurred. Please try again."
    end
  end

  describe "format_password_reset_error/1" do
    test "formats each reason a reset can fail with" do
      assert ErrorFormatter.format_password_reset_error(:rate_limited) ==
               "Too many attempts. Please try again later."

      assert ErrorFormatter.format_password_reset_error(:invalid_token) ==
               "Invalid or expired token"

      assert ErrorFormatter.format_password_reset_error(:token_expired) ==
               "This link has expired. Please request a new one"

      assert ErrorFormatter.format_password_reset_error(:invalid_password) == "Invalid password"
    end

    test "answers an unmapped reason with the server error instead of raising" do
      assert ErrorFormatter.format_password_reset_error(:something_new) ==
               "A server error occurred. Please try again"
    end
  end

  describe "format_validation_errors/1" do
    # The messages are already in the reader's language; no field name is
    # made up in English in front of them.
    test "joins the messages without field names" do
      errors = %{terms_accepted: "Terms of service must be accepted", email: ["is invalid"]}
      result = ErrorFormatter.format_validation_errors(errors)

      assert result =~ "Terms of service must be accepted"
      assert result =~ "is invalid"
      refute result =~ "Terms accepted"
      refute result =~ "Email"
    end
  end

  describe "first_error/2" do
    test "is the first field's first message alone, interpolated" do
      changeset = %Changeset{
        data: %{},
        errors: [
          password:
            {"should be at least %{count} character(s)",
             [count: 8, validation: :length, kind: :min]},
          email: {"can't be blank", [validation: :required]},
          email: {"has invalid format", [validation: :format]}
        ]
      }

      assert ErrorFormatter.first_error(changeset) == "can't be blank"

      assert ErrorFormatter.first_error(changeset, %{email: "Email address"}) ==
               "Email address: can't be blank"
    end

    test "translates the message into the current locale" do
      changeset = %Changeset{
        data: %{},
        errors: [
          new_password:
            {"should be at least %{count} character(s)",
             [count: 8, validation: :length, kind: :min]}
        ]
      }

      assert Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
               ErrorFormatter.first_error(changeset)
             end) == "sollte mindestens 8 Zeichen lang sein"
    end

    test "is nil without errors" do
      assert ErrorFormatter.first_error(%Changeset{data: %{}, errors: []}) == nil
    end

    test "reaches a message nested under an embedded field" do
      changeset =
        %Parent{}
        |> Changeset.cast(%{items: [%{title: "fine"}, %{title: ""}]}, [])
        |> Changeset.cast_embed(:items, with: &Item.changeset/2)

      assert ErrorFormatter.first_error(changeset) == "can't be blank"
    end
  end

  describe "format_user_friendly_error/2" do
    test "answers a unique-constraint refusal on any field with the generic in-use message" do
      changeset = %Changeset{
        data: %{},
        errors: [name: {"has already been taken", [constraint: :unique, constraint_name: "x"]}]
      }

      assert ErrorFormatter.format_user_friendly_error("registration", changeset) ==
               "This information is already in use. Please try with different details."
    end

    # Classified by the refusal's metadata, so it works in every language.
    test "names a refused field in the reader's language" do
      changeset = %Changeset{
        data: %{},
        errors: [
          password:
            {"should be at least %{count} character(s)",
             [count: 8, validation: :length, kind: :min]}
        ]
      }

      message =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          ErrorFormatter.format_user_friendly_error("registration", changeset)
        end)

      assert message ==
               "Registrierung fehlgeschlagen: Passwort: sollte mindestens 8 Zeichen lang sein"
    end

    test "is generic in-use in German too" do
      changeset = %Changeset{
        data: %{},
        errors: [email: {"has already been taken", [constraint: :unique]}]
      }

      assert Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
               ErrorFormatter.format_user_friendly_error("registration", changeset)
             end) =~ "Diese Angaben werden bereits verwendet"
    end
  end

  describe "format_rate_limit_error/1" do
    test "names the operation" do
      assert ErrorFormatter.format_rate_limit_error("authentication") ==
               "Too many authentication attempts. Please try again later."
    end
  end
end
