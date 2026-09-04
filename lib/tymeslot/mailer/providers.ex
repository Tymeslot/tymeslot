defmodule Tymeslot.Mailer.Providers do
  @moduledoc """
  The single registry of email providers Tymeslot supports.

  `EMAIL_ADAPTER` selects one of the names below and everything that varies
  per provider is resolved from this one table: the Swoosh adapter, the
  environment variables carrying its credentials, the shape of the startup
  health check, and how a tracking category translates into provider options.

      | `EMAIL_ADAPTER` | Adapter                    | Kind    | Credentials |
      |-----------------|----------------------------|---------|-------------|
      | `smtp`          | `Swoosh.Adapters.SMTP`     | `:smtp` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TLS_VERIFY`, `SMTP_CACERTFILE` |
      | `postmark`      | `Swoosh.Adapters.Postmark` | `:api`  | `POSTMARK_API_KEY` |
      | `sendgrid`      | `Swoosh.Adapters.Sendgrid` | `:api`  | `SENDGRID_API_KEY` |
      | `mailgun`       | `Swoosh.Adapters.Mailgun`  | `:api`  | `MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, optional `MAILGUN_BASE_URL` |
      | `ahasend`       | `Swoosh.Adapters.AhaSend`  | `:api`  | `AHASEND_API_KEY`, `AHASEND_ACCOUNT_ID` |
      | `test`          | `Swoosh.Adapters.Test`     | `:dev`  | none — mail is discarded |
      | `local`         | `Swoosh.Adapters.Local`    | `:dev`  | none — development mailbox, refused in production |

  `Tymeslot.Mailer.api_providers/0` treats a provider as API-key-based when
  its `kind` is `:api`. `kind`, `probe`, and `dev_only` are three distinct
  fields for three distinct questions: `kind` classifies the transport,
  `probe` names which startup credential check to run (and can be `:none`
  independently of `kind`), and `dev_only` marks the adapters production
  refuses to boot with.

  Any provider Tymeslot does not name here can still be used over `smtp`,
  which every transactional mail service offers.

  ## Adding a provider

  Add one entry to `@providers` — choosing its `kind` (`:api`, `:smtp`, or
  `:dev`) — one `build_config/1` clause reading its environment variables,
  and one `tracking_options/2` clause. Then extend the probe in
  `Tymeslot.Mailer.ApiProbe` if the provider has an endpoint that can
  validate credentials without sending mail, and document the variables in
  `.env.example`. `all/0` is the read side of this registry — downstream docs
  that list provider credentials read them from here (via `Tymeslot.Mailer`)
  rather than restating them by hand, so a new entry here is enough for that
  coverage to pick it up.

  ## Credentials vs. malformed input

  `build/1` returns `{:error, reason}` when a provider's credentials are
  absent, which lets development fall back to the local mailbox while
  production refuses to boot. Values that are *present but malformed* (an
  empty string, a port outside 1-65535) raise in every environment: they are
  a configuration mistake, not an unconfigured provider.
  """

  alias Tymeslot.Mailer.SMTPConfig

  @typedoc "Value of the `EMAIL_ADAPTER` environment variable."
  @type name :: String.t()

  @typedoc """
  Tracking category declared by the caller of
  `Tymeslot.Emails.Shared.MjmlEmail.base_email/1`.

    * `:transactional` — confirmations, security alerts, receipts. No opens,
      no link rewriting.
    * `:lifecycle` — onboarding and billing nudges, where open rates are
      genuinely useful. Opens on, links untouched.
    * `:marketing` — bulk newsletters and announcements. Opens on, links
      rewritten.
  """
  @type tracking :: :transactional | :lifecycle | :marketing

  @typedoc "Transport classification: API-key-based, SMTP, or development-only."
  @type kind :: :api | :smtp | :dev

  @type entry :: %{
          label: String.t(),
          adapter: module(),
          required_config: [atom()],
          env_vars: %{atom() => String.t()},
          optional_env_vars: [String.t()],
          kind: kind(),
          probe: atom(),
          dev_only: boolean()
        }

  @providers %{
    "smtp" => %{
      label: "SMTP",
      adapter: Swoosh.Adapters.SMTP,
      required_config: [:relay, :username, :password],
      env_vars: %{
        relay: "SMTP_HOST",
        username: "SMTP_USERNAME",
        password: "SMTP_PASSWORD"
      },
      optional_env_vars: ["SMTP_PORT", "SMTP_TLS_VERIFY", "SMTP_CACERTFILE"],
      kind: :smtp,
      probe: :smtp,
      dev_only: false
    },
    "postmark" => %{
      label: "Postmark",
      adapter: Swoosh.Adapters.Postmark,
      required_config: [:api_key],
      env_vars: %{api_key: "POSTMARK_API_KEY"},
      optional_env_vars: [],
      kind: :api,
      probe: :postmark,
      dev_only: false
    },
    "sendgrid" => %{
      label: "SendGrid",
      adapter: Swoosh.Adapters.Sendgrid,
      required_config: [:api_key],
      env_vars: %{api_key: "SENDGRID_API_KEY"},
      optional_env_vars: [],
      kind: :api,
      probe: :sendgrid,
      dev_only: false
    },
    "mailgun" => %{
      label: "Mailgun",
      adapter: Swoosh.Adapters.Mailgun,
      required_config: [:api_key, :domain],
      env_vars: %{api_key: "MAILGUN_API_KEY", domain: "MAILGUN_DOMAIN"},
      optional_env_vars: ["MAILGUN_BASE_URL"],
      kind: :api,
      probe: :mailgun,
      dev_only: false
    },
    "ahasend" => %{
      label: "AhaSend",
      adapter: Swoosh.Adapters.AhaSend,
      required_config: [:api_key, :account_id],
      env_vars: %{api_key: "AHASEND_API_KEY", account_id: "AHASEND_ACCOUNT_ID"},
      optional_env_vars: [],
      kind: :api,
      probe: :ahasend,
      dev_only: false
    },
    "test" => %{
      label: "Test",
      adapter: Swoosh.Adapters.Test,
      required_config: [],
      env_vars: %{},
      optional_env_vars: [],
      kind: :dev,
      probe: :none,
      dev_only: false
    },
    "local" => %{
      label: "Local mailbox",
      adapter: Swoosh.Adapters.Local,
      required_config: [],
      env_vars: %{},
      optional_env_vars: [],
      kind: :dev,
      probe: :none,
      dev_only: true
    }
  }

  @names @providers |> Map.keys() |> Enum.sort()

  # Accepted `SMTP_TLS_VERIFY` values. `none` accepts any certificate the relay
  # presents; see `Tymeslot.Mailer.SMTPConfig` for why that is a last resort.
  @tls_verify_modes %{"peer" => :peer, "none" => :none}
  @tls_verify_mode_names @tls_verify_modes |> Map.keys() |> Enum.sort()

  @doc "Every accepted `EMAIL_ADAPTER` value, sorted."
  @spec names() :: [name()]
  def names, do: @names

  @doc """
  Every provider entry, keyed by its `EMAIL_ADAPTER` value.

  This is the read side of the registry: downstream docs that describe
  provider credentials should read them from here rather than restating them
  by hand, so a new `@providers` entry can't silently go undocumented.
  """
  @spec all() :: %{name() => entry()}
  def all, do: @providers

  @doc """
  Looks up a provider by its `EMAIL_ADAPTER` value.

  Raises `ArgumentError` for an unrecognised name rather than silently
  falling back to an adapter that discards mail.
  """
  @spec fetch!(name()) :: entry()
  def fetch!(name) when is_binary(name) do
    case Map.fetch(@providers, String.trim(name)) do
      {:ok, entry} ->
        entry

      :error ->
        raise ArgumentError, """
        Unknown EMAIL_ADAPTER: #{inspect(name)}

        Supported values: #{Enum.join(@names, ", ")}

        Providers without a dedicated adapter can be used over SMTP by setting
        EMAIL_ADAPTER=smtp and pointing SMTP_HOST at the provider's relay.
        """
    end
  end

  @doc "Looks up a provider by the Swoosh adapter module it configures."
  @spec for_adapter(module()) :: {:ok, entry()} | :error
  def for_adapter(adapter) do
    case Enum.find(@providers, fn {_name, entry} -> entry.adapter == adapter end) do
      {_name, entry} -> {:ok, entry}
      nil -> :error
    end
  end

  @doc """
  Builds the `Tymeslot.Mailer` configuration for a provider from the
  environment.

  Returns `{:error, reason}` when the provider's credentials are missing, and
  raises when they are present but malformed. See the module documentation for
  why the two are treated differently.
  """
  @spec build(name()) :: {:ok, keyword()} | {:error, String.t()}
  def build(name) when is_binary(name) do
    name = String.trim(name)
    # Rejects unknown names before any environment reading.
    _entry = fetch!(name)

    build_config(name)
  end

  @doc """
  Same as `build/1` but raises when credentials are missing, so a production
  boot fails loudly instead of starting with mail silently disabled.
  """
  @spec build!(name()) :: keyword()
  def build!(name) do
    case build(name) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "EMAIL_ADAPTER=#{String.trim(name)} is not usable: #{reason}"
    end
  end

  @doc """
  Normalises a possibly-blank environment variable value: `nil` and
  whitespace-only strings both collapse to `nil`, everything else is
  trimmed.

  Used for `EMAIL_ADAPTER` so a blank-but-set `EMAIL_ADAPTER=` falls through
  to the documented default (smtp, or Cloudron auto-detection) rather than
  being looked up as an unknown provider name and raising.
  """
  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Whether a provider exists only for development.

  Production refuses these: Swoosh's in-memory mailbox is disabled there
  (`config :swoosh, local: false`), so the adapter would fail on first send.
  """
  @spec dev_only?(name()) :: boolean()
  def dev_only?(name), do: name |> fetch!() |> Map.fetch!(:dev_only)

  @doc """
  Translates a tracking category into the provider options the configured
  adapter understands.

  Only Postmark models the transactional/broadcast split as a message stream.
  Elsewhere the category controls open and click tracking alone; separating
  bulk mail from transactional reputation is an account-level concern the
  operator configures at the provider (a subaccount, a sending domain, or an
  SES configuration set).
  """
  @spec tracking_options(module(), tracking()) :: keyword()
  def tracking_options(Swoosh.Adapters.Postmark, category) do
    {opens, links, stream} =
      case category do
        :transactional -> {false, "None", "outbound"}
        :lifecycle -> {true, "None", "outbound"}
        :marketing -> {true, "HtmlAndText", "broadcast"}
      end

    [track_opens: opens, track_links: links, message_stream: stream]
  end

  def tracking_options(Swoosh.Adapters.Sendgrid, category) do
    {opens, clicks} = opens_and_clicks(category)

    [
      tracking_settings: %{
        open_tracking: %{enable: opens},
        click_tracking: %{enable: clicks},
        subscription_tracking: %{enable: false}
      }
    ]
  end

  def tracking_options(Swoosh.Adapters.Mailgun, category) do
    {opens, clicks} = opens_and_clicks(category)

    [
      sending_options: %{
        tracking: yes_no(opens or clicks),
        "tracking-opens": yes_no(opens),
        "tracking-clicks": yes_no(clicks)
      }
    ]
  end

  def tracking_options(Swoosh.Adapters.AhaSend, category) do
    {opens, clicks} = opens_and_clicks(category)

    [tracking: %{open: opens, click: clicks}]
  end

  def tracking_options(_adapter, _category), do: []

  defp opens_and_clicks(:transactional), do: {false, false}
  defp opens_and_clicks(:lifecycle), do: {true, false}
  defp opens_and_clicks(:marketing), do: {true, true}

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  # Per-provider environment reading. Each clause returns the keyword list
  # Swoosh expects for its adapter, or an error naming the variables to set.

  defp build_config("smtp") do
    with {:ok, host} <- env_present("SMTP_HOST"),
         {:ok, username} <- env_present("SMTP_USERNAME"),
         {:ok, password} <- env_present("SMTP_PASSWORD") do
      {:ok,
       SMTPConfig.build(
         host: host,
         port: env_port!("SMTP_PORT", 587),
         username: username,
         password: password,
         tls_verify: env_tls_verify!("SMTP_TLS_VERIFY"),
         cacertfile: env_optional("SMTP_CACERTFILE")
       )}
    end
  end

  defp build_config("postmark") do
    with {:ok, api_key} <- env_present("POSTMARK_API_KEY") do
      {:ok, [adapter: Swoosh.Adapters.Postmark, api_key: api_key]}
    end
  end

  defp build_config("sendgrid") do
    with {:ok, api_key} <- env_present("SENDGRID_API_KEY") do
      {:ok, [adapter: Swoosh.Adapters.Sendgrid, api_key: api_key]}
    end
  end

  defp build_config("mailgun") do
    with {:ok, api_key} <- env_present("MAILGUN_API_KEY"),
         {:ok, domain} <- env_present("MAILGUN_DOMAIN") do
      base = [adapter: Swoosh.Adapters.Mailgun, api_key: api_key, domain: domain]

      # EU-hosted Mailgun accounts answer on a different host; the adapter
      # defaults to the US one when :base_url is absent.
      {:ok,
       case env_optional("MAILGUN_BASE_URL") do
         nil -> base
         base_url -> Keyword.put(base, :base_url, base_url)
       end}
    end
  end

  defp build_config("ahasend") do
    with {:ok, api_key} <- env_present("AHASEND_API_KEY"),
         {:ok, account_id} <- env_present("AHASEND_ACCOUNT_ID") do
      {:ok, [adapter: Swoosh.Adapters.AhaSend, api_key: api_key, account_id: account_id]}
    end
  end

  defp build_config("test"), do: {:ok, [adapter: Swoosh.Adapters.Test]}
  defp build_config("local"), do: {:ok, [adapter: Swoosh.Adapters.Local]}

  # Absent means "not configured" and is recoverable; set-but-blank is a
  # mistake worth stopping for, in every environment.
  defp env_present(var) do
    case System.get_env(var) do
      nil ->
        {:error, "#{var} is not set"}

      value ->
        if String.trim(value) == "" do
          raise ArgumentError, "#{var} cannot be empty or whitespace-only"
        end

        {:ok, String.trim(value)}
    end
  end

  defp env_optional(var) do
    var |> System.get_env() |> blank_to_nil()
  end

  defp env_tls_verify!(var) do
    case env_optional(var) do
      nil ->
        :peer

      value ->
        case Map.fetch(@tls_verify_modes, String.downcase(value)) do
          {:ok, mode} ->
            mode

          :error ->
            raise ArgumentError,
                  "Invalid #{var}: #{inspect(value)} " <>
                    "(expected one of: #{Enum.join(@tls_verify_mode_names, ", ")})"
        end
    end
  end

  defp env_port!(var, default) do
    case System.get_env(var) do
      nil ->
        default

      value ->
        case Integer.parse(String.trim(value)) do
          {port, ""} when port in 1..65_535 -> port
          _other -> raise ArgumentError, "Invalid #{var}: #{inspect(value)} (expected 1-65535)"
        end
    end
  end
end
