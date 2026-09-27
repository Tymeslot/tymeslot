defmodule Tymeslot.Infrastructure.DeploymentType do
  @moduledoc """
  Normalises the `DEPLOYMENT_TYPE` environment variable.

  `"cloudron"` and its legacy spelling `"main"` both mean Cloudron; every
  other value, unset included, means `"docker"` (Railway and bare releases
  among them). `config/runtime.exs` selects the database config, WebSocket
  origins, URL scheme and SMTP auto-detection from this value, so anything
  else deciding "am I on Cloudron?" should ask here rather than compare the
  raw variable, which misses `"main"`.
  """

  @type t :: String.t()

  @doc """
  Returns the normalised deployment type for a raw `DEPLOYMENT_TYPE` value.
  """
  @spec normalise(String.t() | nil) :: t()
  def normalise("cloudron"), do: "cloudron"
  def normalise("main"), do: "cloudron"
  def normalise(_other), do: "docker"

  @doc """
  Returns the normalised deployment type of the running instance.
  """
  @spec current() :: t()
  def current, do: normalise(System.get_env("DEPLOYMENT_TYPE"))
end
