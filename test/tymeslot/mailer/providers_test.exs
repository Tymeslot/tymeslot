defmodule Tymeslot.Mailer.ProvidersTest do
  # async: false — every build/1 case reads process-global environment
  # variables, which cannot be manipulated safely from concurrent tests.
  use ExUnit.Case, async: false
  @moduletag :mailer

  alias Tymeslot.Mailer.Providers

  # Each test declares exactly the variables it needs, so an operator's shell
  # (or a previously run test) can never make one pass by accident.
  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "names/0 and fetch!/1" do
    test "every documented adapter name is accepted" do
      assert Providers.names() == [
               "ahasend",
               "local",
               "mailgun",
               "postmark",
               "sendgrid",
               "smtp",
               "test"
             ]
    end

    test "resolves a name to its Swoosh adapter" do
      assert %{adapter: Swoosh.Adapters.AhaSend} = Providers.fetch!("ahasend")
      assert %{adapter: Swoosh.Adapters.Sendgrid} = Providers.fetch!("sendgrid")
      assert %{adapter: Swoosh.Adapters.Mailgun} = Providers.fetch!("mailgun")
    end

    test "tolerates surrounding whitespace" do
      assert %{adapter: Swoosh.Adapters.Postmark} = Providers.fetch!("  postmark\n")
    end

    test "all/0 returns every entry keyed by its EMAIL_ADAPTER name" do
      all = Providers.all()

      assert Enum.sort(Map.keys(all)) == [
               "ahasend",
               "local",
               "mailgun",
               "postmark",
               "sendgrid",
               "smtp",
               "test"
             ]

      assert %{label: "Postmark", adapter: Swoosh.Adapters.Postmark} = all["postmark"]
    end

    test "raises on an unknown name and lists the supported ones" do
      error = assert_raise(ArgumentError, fn -> Providers.fetch!("mailchimp") end)

      assert error.message =~ ~s(Unknown EMAIL_ADAPTER: "mailchimp")
      assert error.message =~ "ahasend, local, mailgun, postmark, sendgrid, smtp, test"
      assert error.message =~ "EMAIL_ADAPTER=smtp"
    end
  end

  describe "build/1 for the API providers" do
    test "builds SendGrid configuration from SENDGRID_API_KEY" do
      with_env([{"SENDGRID_API_KEY", "SG.test-key"}], fn ->
        assert {:ok, config} = Providers.build("sendgrid")
        assert config[:adapter] == Swoosh.Adapters.Sendgrid
        assert config[:api_key] == "SG.test-key"
      end)
    end

    test "builds AhaSend configuration from both of its variables" do
      with_env([{"AHASEND_API_KEY", "aha-sk-key"}, {"AHASEND_ACCOUNT_ID", "acct-1"}], fn ->
        assert {:ok, config} = Providers.build("ahasend")
        assert config[:adapter] == Swoosh.Adapters.AhaSend
        assert config[:api_key] == "aha-sk-key"
        assert config[:account_id] == "acct-1"
      end)
    end

    test "omits the Mailgun base URL when it is not set" do
      with_env(
        [
          {"MAILGUN_API_KEY", "key"},
          {"MAILGUN_DOMAIN", "mg.example.com"},
          {"MAILGUN_BASE_URL", nil}
        ],
        fn ->
          assert {:ok, config} = Providers.build("mailgun")
          assert config[:domain] == "mg.example.com"
          refute Keyword.has_key?(config, :base_url)
        end
      )
    end

    test "passes the Mailgun base URL through for EU accounts" do
      with_env(
        [
          {"MAILGUN_API_KEY", "key"},
          {"MAILGUN_DOMAIN", "mg.example.com"},
          {"MAILGUN_BASE_URL", "https://api.eu.mailgun.net/v3"}
        ],
        fn ->
          assert {:ok, config} = Providers.build("mailgun")
          assert config[:base_url] == "https://api.eu.mailgun.net/v3"
        end
      )
    end

    test "reports missing credentials as an error naming the variable" do
      with_env([{"SENDGRID_API_KEY", nil}], fn ->
        assert {:error, message} = Providers.build("sendgrid")
        assert message =~ "SENDGRID_API_KEY is not set"
      end)
    end

    test "reports the first missing variable when a provider needs several" do
      with_env([{"MAILGUN_API_KEY", "key"}, {"MAILGUN_DOMAIN", nil}], fn ->
        assert {:error, message} = Providers.build("mailgun")
        assert message =~ "MAILGUN_DOMAIN is not set"
      end)
    end

    test "raises when a credential is set but blank" do
      with_env([{"AHASEND_API_KEY", "   "}], fn ->
        assert_raise ArgumentError, ~r/AHASEND_API_KEY cannot be empty/, fn ->
          Providers.build("ahasend")
        end
      end)
    end
  end

  describe "build/1 for SMTP and the development adapters" do
    test "builds SMTP configuration and defaults the port to 587" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_PORT", nil}
        ],
        fn ->
          assert {:ok, config} = Providers.build("smtp")
          assert config[:adapter] == Swoosh.Adapters.SMTP
          assert config[:relay] == "smtp.example.com"
          assert config[:port] == 587
        end
      )
    end

    test "SMTP_TLS_VERIFY=none turns off certificate verification" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_TLS_VERIFY", "none"}
        ],
        fn ->
          assert {:ok, config} = Providers.build("smtp")
          assert config[:tls_options][:verify] == :verify_none
        end
      )
    end

    test "verification stays on when SMTP_TLS_VERIFY is unset" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_TLS_VERIFY", nil}
        ],
        fn ->
          assert {:ok, config} = Providers.build("smtp")
          assert config[:tls_options][:verify] == :verify_peer
        end
      )
    end

    test "SMTP_CACERTFILE replaces the public trust store" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_CACERTFILE", CAStore.file_path()}
        ],
        fn ->
          assert {:ok, config} = Providers.build("smtp")
          assert config[:tls_options][:cacertfile] == CAStore.file_path()
        end
      )
    end

    test "raises on an unrecognised SMTP_TLS_VERIFY" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_TLS_VERIFY", "insecure"}
        ],
        fn ->
          assert_raise ArgumentError, ~r/Invalid SMTP_TLS_VERIFY/, fn ->
            Providers.build("smtp")
          end
        end
      )
    end

    test "raises on an unparsable SMTP port" do
      with_env(
        [
          {"SMTP_HOST", "smtp.example.com"},
          {"SMTP_USERNAME", "user@example.com"},
          {"SMTP_PASSWORD", "secret"},
          {"SMTP_PORT", "not-a-port"}
        ],
        fn ->
          assert_raise ArgumentError, ~r/Invalid SMTP_PORT/, fn -> Providers.build("smtp") end
        end
      )
    end

    test "the development adapters need no credentials" do
      assert {:ok, [adapter: Swoosh.Adapters.Test]} = Providers.build("test")
      assert {:ok, [adapter: Swoosh.Adapters.Local]} = Providers.build("local")
    end
  end

  describe "build!/1" do
    test "raises rather than returning an unusable configuration" do
      with_env([{"SENDGRID_API_KEY", nil}], fn ->
        assert_raise ArgumentError, ~r/EMAIL_ADAPTER=sendgrid is not usable/, fn ->
          Providers.build!("sendgrid")
        end
      end)
    end
  end

  describe "blank_to_nil/1" do
    test "nil stays nil" do
      assert Providers.blank_to_nil(nil) == nil
    end

    test "an empty string collapses to nil" do
      assert Providers.blank_to_nil("") == nil
    end

    test "a whitespace-only string collapses to nil" do
      assert Providers.blank_to_nil("   ") == nil
    end

    test "a real value is trimmed and kept" do
      assert Providers.blank_to_nil("  smtp  ") == "smtp"
    end
  end

  describe "dev_only?/1" do
    test "only the local mailbox is refused in production" do
      assert Providers.dev_only?("local")
      refute Providers.dev_only?("test")
      refute Providers.dev_only?("smtp")
      refute Providers.dev_only?("ahasend")
    end
  end

  describe "tracking_options/2" do
    test "Postmark keeps opens, links and the message stream" do
      assert Providers.tracking_options(Swoosh.Adapters.Postmark, :transactional) == [
               track_opens: false,
               track_links: "None",
               message_stream: "outbound"
             ]

      assert Providers.tracking_options(Swoosh.Adapters.Postmark, :lifecycle) == [
               track_opens: true,
               track_links: "None",
               message_stream: "outbound"
             ]

      assert Providers.tracking_options(Swoosh.Adapters.Postmark, :marketing) == [
               track_opens: true,
               track_links: "HtmlAndText",
               message_stream: "broadcast"
             ]
    end

    test "SendGrid receives the category as tracking settings" do
      assert [tracking_settings: settings] =
               Providers.tracking_options(Swoosh.Adapters.Sendgrid, :lifecycle)

      assert settings.open_tracking == %{enable: true}
      assert settings.click_tracking == %{enable: false}
      assert settings.subscription_tracking == %{enable: false}
    end

    test "Mailgun receives the category as sending options" do
      assert [sending_options: options] =
               Providers.tracking_options(Swoosh.Adapters.Mailgun, :marketing)

      assert options.tracking == "yes"
      assert options[:"tracking-opens"] == "yes"
      assert options[:"tracking-clicks"] == "yes"
    end

    test "AhaSend receives the category as its tracking map" do
      assert [tracking: %{open: false, click: false}] =
               Providers.tracking_options(Swoosh.Adapters.AhaSend, :transactional)
    end

    test "transactional email is never tracked, whichever provider is configured" do
      assert [track_opens: false, track_links: "None", message_stream: "outbound"] =
               Providers.tracking_options(Swoosh.Adapters.Postmark, :transactional)

      assert [
               tracking_settings: %{
                 open_tracking: %{enable: false},
                 click_tracking: %{enable: false}
               }
             ] = Providers.tracking_options(Swoosh.Adapters.Sendgrid, :transactional)

      assert [sending_options: %{tracking: "no", "tracking-opens": "no"}] =
               Providers.tracking_options(Swoosh.Adapters.Mailgun, :transactional)

      assert [tracking: %{open: false, click: false}] =
               Providers.tracking_options(Swoosh.Adapters.AhaSend, :transactional)
    end

    test "providers without tracking options are left alone" do
      assert Providers.tracking_options(Swoosh.Adapters.SMTP, :marketing) == []
      assert Providers.tracking_options(Swoosh.Adapters.Test, :lifecycle) == []
    end
  end
end
