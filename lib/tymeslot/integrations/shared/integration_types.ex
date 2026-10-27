defmodule Tymeslot.Integrations.Shared.IntegrationTypes do
  @moduledoc """
  The two kinds of integration, calendar and video, and the modules and
  values that differ between them.

  Code that handles both kinds (health checks, reauth flagging, auto-pause)
  looks a kind up here instead of switching on `:calendar | :video` itself,
  so a behaviour added for one kind cannot silently miss the other.
  """

  alias Tymeslot.Integrations.Calendar.{
    CalendarIntegrationQueries,
    CalendarIntegrationSchema,
    Management
  }

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.{VideoIntegrationQueries, VideoIntegrationSchema}

  @type kind :: :calendar | :video

  @kinds [:calendar, :video]

  @doc "Every kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kind stored as `value` in an `integration_type` column, or `:error`."
  @spec parse(String.t() | atom()) :: {:ok, kind()} | :error
  def parse(kind) when kind in @kinds, do: {:ok, kind}
  def parse("calendar"), do: {:ok, :calendar}
  def parse("video"), do: {:ok, :video}
  def parse(_other), do: :error

  @doc "The kind as stored in an `integration_type` column."
  @spec db_value(kind()) :: String.t()
  def db_value(kind) when kind in @kinds, do: Atom.to_string(kind)

  @doc "The kind's integration queries module."
  @spec queries(kind()) :: module()
  def queries(:calendar), do: CalendarIntegrationQueries
  def queries(:video), do: VideoIntegrationQueries

  @doc "The kind's integration schema."
  @spec schema(kind()) :: module()
  def schema(:calendar), do: CalendarIntegrationSchema
  def schema(:video), do: VideoIntegrationSchema

  @doc """
  The kind's context, which owns `handle_reauth_required/2` and
  `pause_integration/1`.
  """
  @spec domain(kind()) :: module()
  def domain(:calendar), do: Management
  def domain(:video), do: Video

  @doc "A short label for log lines."
  @spec log_name(kind()) :: String.t()
  def log_name(:calendar), do: "Calendar"
  def log_name(:video), do: "Video"
end
