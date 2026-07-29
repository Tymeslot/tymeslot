defmodule Tymeslot.Mailer.Providers do
  @moduledoc """
  The single registry of email providers Tymeslot supports.

  `EMAIL_ADAPTER` selects one of the names below and everything that varies
  per provider is resolved from this one table: the Swoosh adapter, the
  environment variables carrying its credentials, the shape of the startup
  health check, and how a tracking category translates into provider options.

      | `EMAIL_ADAPTER` | Adapter                    | Credentials |
      |-----------------|----------------------------|-------------|
      | `smtp`          | `Swoosh.Adapters.SMTP`     | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` |
      | `postmark`      | `Swoosh.Adapters.Postmark` | `POSTMARK_API_KEY` |
      | `sendgrid`      | `Swoosh.Adapters.Sendgrid` | `SENDGRID_API_KEY` |
      | `mailgun`       | `Swoosh.Adapters.Mailgun`  | `MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, optional `MAILGUN_BASE_URL` |
      | `ahasend`       | `Swoosh.Adapters.AhaSend`  | `AHASEND_API_KEY`, `AHASEND_ACCOUNT_ID` |
      | `test`          | `Swoosh.Adapters.Test`     | none — mail is discarded |
      | `local`         | `Swoosh.Adapters.Local`    | none — development mailbox, refused in production |

  Any provider Tymeslot does not name here can still be used over `smtp`,
  which every transactional mail service offers.

  ## Adding a provider

  Add one entry to `@providers`, one `build_config/1` clause reading its
  environment variables, and one `tracking_options/2` clause. Then extend the
  probe in `Tymeslot.Mailer.ApiProbe` if the provider has an endpoint that can
  validate credentials without sending mail, and document the variables in
  `.env.example`.

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

  @type entry :: %{
          label: String.t(),
          adapter: module(),
          required_config: [atom()],
          env_vars: %{atom() => String.t()},
          optional_env_vars: [String.t()],
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
      optional_env_vars: ["SMTP_PORT"],
      probe: :smtp,
      dev_only: false
    },
    "postmark" => %{
      label: "Postmark",
      adapter: Swoosh.Adapters.Postmark,
      required_config: [:api_key],
      env_vars: %{api_key: "POSTMARK_API_KEY"},
      optional_env_vars: [],
      probe: :postmark,
      dev_only: false
    },
    "sendgrid" => %{
      label: "SendGrid",
      adapter: Swoosh.Adapters.Sendgrid,
      required_config: [:api_key],
      env_vars: %{api_key: "SENDGRID_API_KEY"},
      optional_env_vars: [],
      probe: :sendgrid,
      dev_only: false
    },
    "mailgun" => %{
      label: "Mailgun",
      adapter: Swoosh.Adapters.Mailgun,
      required_config: [:api_key, :domain],
      env_vars: %{api_key: "MAILGUN_API_KEY", domain: "MAILGUN_DOMAIN"},
      optional_env_vars: ["MAILGUN_BASE_URL"],
      probe: :mailgun,
      dev_only: false
    },
    "ahasend" => %{
      label: "AhaSend",
      adapter: Swoosh.Adapters.AhaSend,
      required_config: [:api_key, :account_id],
      env_vars: %{api_key: "AHASEND_API_KEY", account_id: "AHASEND_ACCOUNT_ID"},
      optional_env_vars: [],
      probe: :ahasend,
      dev_only: false
    },
    "test" => %{
      label: "Test",
      adapter: Swoosh.Adapters.Test,
      required_config: [],
      env_vars: %{},
      optional_env_vars: [],
      probe: :none,
      dev_only: false
    },
    "local" => %{
      label: "Local mailbox",
      adapter: Swoosh.Adapters.Local,
      required_config: [],
      env_vars: %{},
      optional_env_vars: [],
      probe: :none,
      dev_only: true
    }
  }

  @names @providers |> Map.keys() |> Enum.sort()

  @doc "Every accepted `EMAIL_ADAPTER` value, sorted."
  @spec names() :: [name()]
  def names, do: @names

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
         password: password
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
    case System.get_env(var) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
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
