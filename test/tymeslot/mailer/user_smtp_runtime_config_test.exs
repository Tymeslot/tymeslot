defmodule Tymeslot.Mailer.UserSmtpRuntimeConfigTest do
  @moduledoc "Verifies the strict deployment opt-in for user-owned SMTP connections."

  # Runtime config reads the OS environment; these tests must run synchronously.
  use ExUnit.Case, async: false

  @moduletag :mailer
  @moduletag :unit

  alias Config.Reader

  @env_var "USER_SMTP_ENABLED"
  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)

  setup do
    previous = System.get_env(@env_var)

    on_exit(fn ->
      if previous, do: System.put_env(@env_var, previous), else: System.delete_env(@env_var)
    end)

    :ok
  end

  test "unset preserves the default or overlay configuration" do
    System.delete_env(@env_var)
    refute Keyword.has_key?(runtime_config(), :user_smtp_enabled)
  end

  test "explicit true enables and false disables the boundary" do
    System.put_env(@env_var, "true")
    assert runtime_config()[:user_smtp_enabled] == true

    System.put_env(@env_var, "false")
    assert runtime_config()[:user_smtp_enabled] == false
  end

  test "a typo or empty flag refuses startup" do
    for value <- ["", "TRUE", "1", "yes", " false ", "flase"] do
      System.put_env(@env_var, value)

      assert_raise RuntimeError, "USER_SMTP_ENABLED must be true or false", fn ->
        runtime_config()
      end
    end
  end

  defp runtime_config do
    @runtime_exs
    |> Reader.read!(env: :test, target: :host)
    |> Keyword.get(:tymeslot, [])
  end
end
