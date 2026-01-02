defmodule Tymeslot.Integrations.Calendar.CalDAV.ClientBehaviour do
  @moduledoc """
  Behaviour for CalDAV Provider to enable mocking in tests.
  """

  @type client :: %{
          base_url: String.t(),
          username: String.t(),
          password: String.t(),
          calendar_path: String.t()
        }

  @type event :: %{
          uid: String.t(),
          summary: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          description: String.t() | nil,
          location: String.t() | nil
        }

  @callback get_events(client(), DateTime.t(), DateTime.t()) ::
              {:ok, [event()]} | {:error, term()}
  @callback create_event(client(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback update_event(client(), String.t(), map()) :: :ok | {:error, term()}
  @callback delete_event(client(), String.t()) :: :ok | {:error, term()}
end
