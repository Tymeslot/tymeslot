defmodule Tymeslot.Integrations.Calendar.CalendarBehaviour do
  @moduledoc """
  Behaviour for calendar operations to enable testing with mocks.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @callback get_events_for_range_fresh(pos_integer(), Date.t(), Date.t()) ::
              {:ok, list()} | {:error, any()}
  @callback get_events_for_month(pos_integer(), pos_integer(), pos_integer(), String.t()) ::
              {:ok, list()} | {:error, any()}
  @callback get_event(binary(), pos_integer() | nil) :: {:ok, any()} | {:error, any()}
  @callback create_event(
              map(),
              pos_integer()
              | MeetingSchema.t()
              | MeetingTypeSchema.t()
              | {pos_integer(), pos_integer()}
              | nil
            ) ::
              {:ok, any()} | {:error, any()}
  @callback update_event(
              binary(),
              map(),
              pos_integer()
              | MeetingSchema.t()
              | MeetingTypeSchema.t()
              | {pos_integer(), pos_integer()}
              | nil
            ) ::
              :ok | {:error, any()}
  @callback delete_event(
              binary(),
              pos_integer()
              | MeetingSchema.t()
              | MeetingTypeSchema.t()
              | {pos_integer(), pos_integer()}
              | nil
            ) ::
              :ok | {:error, any()}
  @callback get_booking_integration_info(pos_integer() | MeetingTypeSchema.t()) ::
              {:ok,
               %{
                 required(:integration_id) => pos_integer(),
                 required(:calendar_path) => String.t()
               }}
              | {:error, any()}
end
