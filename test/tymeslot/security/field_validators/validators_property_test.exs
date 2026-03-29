defmodule Tymeslot.Security.FieldValidators.ValidatorsPropertyTest do
  @moduledoc """
  Property-based robustness tests for field validators.
  Ensures validators never crash on arbitrary input and that known-valid
  inputs always pass.
  """
  use ExUnit.Case, async: true
  @moduletag :security
  use ExUnitProperties

  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.FieldValidators.UsernameValidator

  # -- Email Validator --

  describe "EmailValidator" do
    property "never crashes on arbitrary strings" do
      check all(s <- string(:printable)) do
        result = EmailValidator.validate(s)
        assert match?(:ok, result) or match?({:error, _reason}, result)
      end
    end

    property "never crashes on non-string types" do
      check all(
              value <-
                one_of([
                  integer(),
                  float(),
                  constant(nil),
                  constant(true),
                  list_of(integer(), max_length: 3)
                ])
            ) do
        result = EmailValidator.validate(value)
        assert match?(:ok, result) or match?({:error, _reason}, result)
      end
    end

    property "well-formed emails always pass" do
      check all(
              local <- string(:alphanumeric, min_length: 1, max_length: 20),
              domain <- string(:alphanumeric, min_length: 1, max_length: 15),
              tld <- member_of(["com", "org", "net", "io", "dev"])
            ) do
        email = "#{String.downcase(local)}@#{String.downcase(domain)}.#{tld}"
        assert :ok = EmailValidator.validate(email)
      end
    end

    property "missing @ always fails" do
      check all(s <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        refute String.contains?(s, "@")
        assert {:error, _msg} = EmailValidator.validate(s)
      end
    end
  end

  # -- Password Validator --

  describe "PasswordValidator" do
    property "never crashes on arbitrary strings" do
      check all(s <- string(:printable)) do
        result = PasswordValidator.validate(s)
        assert match?(:ok, result) or match?({:error, _reason}, result)
      end
    end

    property "passwords meeting all requirements always pass" do
      check all(
              lower <- string(Enum.to_list(?a..?z), min_length: 1, max_length: 10),
              upper <- string(Enum.to_list(?A..?Z), min_length: 1, max_length: 10),
              digit <- string(Enum.to_list(?0..?9), min_length: 1, max_length: 5),
              special <- member_of(["!", "@", "#", "$", "%", "^", "&", "*"])
            ) do
        password = lower <> upper <> digit <> special

        if String.length(password) >= 8 and String.length(password) <= 80 do
          assert :ok = PasswordValidator.validate(password)
        end
      end
    end

    property "too-short passwords always fail" do
      check all(s <- string(:printable, min_length: 1, max_length: 7)) do
        assert {:error, "Password must be at least 8 characters long"} =
                 PasswordValidator.validate(s)
      end
    end

    property "confirmation must match exactly" do
      check all(
              pw <- string(:printable, min_length: 8, max_length: 40),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 5)
            ) do
        assert {:error, _msg} = PasswordValidator.validate_confirmation(pw, pw <> suffix)
      end
    end

    property "matching confirmation always passes" do
      check all(pw <- string(:printable, min_length: 8, max_length: 40)) do
        assert :ok = PasswordValidator.validate_confirmation(pw, pw)
      end
    end
  end

  # -- Username Validator --

  describe "UsernameValidator" do
    property "never crashes on arbitrary strings" do
      check all(s <- string(:printable)) do
        result = UsernameValidator.validate(s)
        assert match?(:ok, result) or match?({:error, _reason}, result)
      end
    end

    property "valid usernames always pass" do
      check all(
              first_char <- member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)),
              rest <-
                string(
                  Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ ~c"_-",
                  min_length: 2,
                  max_length: 20
                )
            ) do
        username = <<first_char>> <> rest

        reserved =
          ~w[admin api www mail ftp login signup auth dashboard profile settings help support contact about privacy terms blog news home index root test demo]

        unless String.downcase(username) in reserved do
          assert :ok = UsernameValidator.validate(username)
        end
      end
    end

    property "too-short usernames always fail" do
      check all(
              s <-
                string(
                  Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9),
                  min_length: 1,
                  max_length: 2
                )
            ) do
        assert {:error, _msg} = UsernameValidator.validate(s)
      end
    end

    property "uppercase characters always fail" do
      check all(
              prefix <- string(Enum.to_list(?a..?z), min_length: 3, max_length: 10),
              upper <- string(Enum.to_list(?A..?Z), min_length: 1, max_length: 3)
            ) do
        # Inject uppercase somewhere
        username = prefix <> upper
        assert {:error, _msg} = UsernameValidator.validate(username)
      end
    end
  end
end
