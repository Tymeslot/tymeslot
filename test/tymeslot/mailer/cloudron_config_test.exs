defmodule Tymeslot.Mailer.CloudronConfigTest do
  use ExUnit.Case, async: true
  @moduletag :mailer

  alias Tymeslot.Mailer.CloudronConfig

  describe "build/1" do
    test "creates SMTP config from Cloudron environment variables" do
      config =
        CloudronConfig.build(
          server: "mail",
          port: "25",
          username: "app",
          password: "secret"
        )

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "mail"
      assert config[:port] == 25
      assert config[:username] == "app"
      assert config[:password] == "secret"
      assert config[:ssl] == false
      assert config[:tls] == :never
      assert config[:auth] == :always
      assert config[:no_mx_lookups] == true
    end

    test "port is parsed from string to integer" do
      config =
        CloudronConfig.build(
          server: "mail",
          port: "587",
          username: "app",
          password: "secret"
        )

      assert config[:port] == 587
    end

    test "port defaults to 25 when nil" do
      config =
        CloudronConfig.build(
          server: "mail",
          port: nil,
          username: "app",
          password: "secret"
        )

      assert config[:port] == 25
    end

    test "raises when server is nil" do
      assert_raise ArgumentError, ~r/CLOUDRON_MAIL_SMTP_SERVER/, fn ->
        CloudronConfig.build(
          server: nil,
          port: "25",
          username: "app",
          password: "secret"
        )
      end
    end

    test "raises when server is empty" do
      assert_raise ArgumentError, ~r/CLOUDRON_MAIL_SMTP_SERVER/, fn ->
        CloudronConfig.build(
          server: "",
          port: "25",
          username: "app",
          password: "secret"
        )
      end
    end

    test "raises when username is nil" do
      assert_raise ArgumentError, ~r/CLOUDRON_MAIL_SMTP_USERNAME/, fn ->
        CloudronConfig.build(
          server: "mail",
          port: "25",
          username: nil,
          password: "secret"
        )
      end
    end

    test "raises when password is nil" do
      assert_raise ArgumentError, ~r/CLOUDRON_MAIL_SMTP_PASSWORD/, fn ->
        CloudronConfig.build(
          server: "mail",
          port: "25",
          username: "app",
          password: nil
        )
      end
    end

    test "raises when port is not a valid integer" do
      assert_raise ArgumentError, ~r/CLOUDRON_MAIL_SMTP_PORT/, fn ->
        CloudronConfig.build(
          server: "mail",
          port: "abc",
          username: "app",
          password: "secret"
        )
      end
    end
  end
end
