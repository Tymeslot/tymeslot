import Config

# Configure environment
config :tymeslot, environment: :prod

# Get deployment type and configure check_origin accordingly
deployment_type = System.get_env("DEPLOYMENT_TYPE", "docker")

check_origin_config =
  case deployment_type do
    "cloudron" ->
      false

    "docker" ->
      case System.get_env("PHX_HOST") do
        nil -> false
        host -> ["https://#{host}", "http://#{host}"]
      end

    _ ->
      false
  end

config :tymeslot, TymeslotWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: check_origin_config,
  session_signing_salt:
    "fG3IVl7dIf6RdFtnyRlEKzAM7rUMDaa5CF04gOsCC+Be0mINFyJLNYKAZj1GDbTdTL7QaZ/+biEC3EGKmi+ATg==",
  live_view: [
    signing_salt:
      "vrKFWytjf6InteaiLuJFILgS9NNY0IZMK+lQtcE5qWV+OfEkgiZGGaSmYwwNfmUcCWcCAnKxNu6gmDRz+Mb7/Q=="
  ]

# Upload directory
config :tymeslot, :upload_directory, "/app/data/uploads"

# Enable secure cookies in production
config :tymeslot, :secure_cookies, true

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Tymeslot.Finch

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

