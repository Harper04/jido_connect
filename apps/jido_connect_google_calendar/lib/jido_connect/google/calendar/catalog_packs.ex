defmodule Jido.Connect.Google.Calendar.CatalogPacks do
  @moduledoc "Curated catalog packs for common Google Calendar tool surfaces."

  alias Jido.Connect.Catalog.Pack

  @reader_tools [
    "google.calendar.calendar.get",
    "google.calendar.calendar.list",
    "google.calendar.calendar_list.get",
    "google.calendar.event.list",
    "google.calendar.event.get",
    "google.calendar.event.instances",
    "google.calendar.freebusy.query",
    "google.calendar.availability.find",
    "google.calendar.acl.list",
    "google.calendar.acl.get"
  ]

  @watch_tools @reader_tools ++
                 [
                   "google.calendar.event.watch",
                   "google.calendar.calendar_list.watch",
                   "google.calendar.acl.watch",
                   "google.calendar.settings.watch",
                   "google.calendar.channel.stop"
                 ]

  @scheduler_tools @reader_tools ++
                     [
                       "google.calendar.event.create",
                       "google.calendar.event.update",
                       "google.calendar.event.move"
                     ]

  @manager_tools @scheduler_tools ++
                   [
                     "google.calendar.event.delete",
                     "google.calendar.calendar.create",
                     "google.calendar.calendar.patch",
                     "google.calendar.calendar.update",
                     "google.calendar.calendar.delete",
                     "google.calendar.calendar.clear",
                     "google.calendar.calendar_list.create",
                     "google.calendar.calendar_list.patch",
                     "google.calendar.calendar_list.update",
                     "google.calendar.calendar_list.delete",
                     "google.calendar.acl.create",
                     "google.calendar.acl.patch",
                     "google.calendar.acl.update",
                     "google.calendar.acl.delete"
                   ]

  @doc "Returns all built-in Google Calendar catalog packs."
  def all, do: [reader(), scheduler(), watch(), manager()]

  @doc "Read-only Calendar pack for calendar and event reads, freebusy, and availability."
  def reader do
    Pack.new!(%{
      id: :google_calendar_reader,
      label: "Google Calendar reader",
      description: "Read calendars and events, query free/busy windows, and find availability.",
      filters: %{provider: :google_calendar},
      allowed_tools: @reader_tools,
      metadata: %{package: :jido_connect_google_calendar, risk: :read}
    })
  end

  @doc "Calendar scheduling pack with read, availability, and non-destructive event tools."
  def scheduler do
    Pack.new!(%{
      id: :google_calendar_scheduler,
      label: "Google Calendar scheduler",
      description:
        "Read Calendar context, find availability, and create, update, or move events.",
      filters: %{provider: :google_calendar},
      allowed_tools: @scheduler_tools,
      metadata: %{package: :jido_connect_google_calendar, risk: :write}
    })
  end

  @doc "Calendar watch channel lifecycle pack for push notification setup."
  def watch do
    Pack.new!(%{
      id: :google_calendar_watch,
      label: "Google Calendar watch",
      description: "Read Calendar metadata and manage Calendar push notification channels.",
      filters: %{provider: :google_calendar},
      allowed_tools: @watch_tools,
      metadata: %{package: :jido_connect_google_calendar, risk: :write}
    })
  end

  @doc "Calendar management pack with event, calendar, calendar-list, and ACL mutation tools."
  def manager do
    Pack.new!(%{
      id: :google_calendar_manager,
      label: "Google Calendar manager",
      description:
        "Manage Calendar events, calendar metadata, calendar-list entries, and ACL sharing rules.",
      filters: %{provider: :google_calendar},
      allowed_tools: @manager_tools,
      metadata: %{package: :jido_connect_google_calendar, risk: :destructive}
    })
  end
end
