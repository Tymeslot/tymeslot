--
-- PostgreSQL database dump
--

\restrict fgOvFznF3h80d0g7kMBCd73tBexwbZF1R5JpvptfvFUYwogjcfumxeGqdnm8oq2

-- Dumped from database version 16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: analytics_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_events (
    id bigint NOT NULL,
    event_type character varying(255) NOT NULL,
    path character varying(255) NOT NULL,
    meeting_type_id bigint,
    user_id bigint,
    session_id character varying(255),
    visitor_hash character varying(255) NOT NULL,
    utm_source character varying(255),
    utm_medium character varying(255),
    utm_campaign character varying(255),
    utm_content character varying(255),
    utm_term character varying(255),
    referrer_host character varying(255),
    tracking_params jsonb DEFAULT '{}'::jsonb NOT NULL,
    user_agent_family character varying(255),
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: analytics_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.analytics_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: analytics_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.analytics_events_id_seq OWNED BY public.analytics_events.id;


--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    id bigint NOT NULL,
    registration_enabled boolean,
    password_auth_enabled boolean,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    google_auth_enabled boolean,
    github_auth_enabled boolean,
    oauth_auth_enabled boolean,
    recaptcha_signup_enabled boolean,
    recaptcha_booking_enabled boolean,
    recaptcha_signup_min_score double precision,
    recaptcha_booking_min_score double precision,
    admin_alerts_enabled boolean,
    admin_alert_email character varying(255),
    CONSTRAINT app_settings_singleton CHECK ((id = 1))
);


--
-- Name: app_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.app_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.app_settings_id_seq OWNED BY public.app_settings.id;


--
-- Name: availability_breaks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.availability_breaks (
    id bigint NOT NULL,
    weekly_availability_id bigint NOT NULL,
    start_time time(0) without time zone NOT NULL,
    end_time time(0) without time zone NOT NULL,
    label character varying(255),
    sort_order integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: availability_breaks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.availability_breaks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: availability_breaks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.availability_breaks_id_seq OWNED BY public.availability_breaks.id;


--
-- Name: availability_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.availability_overrides (
    id bigint NOT NULL,
    profile_id bigint NOT NULL,
    date date NOT NULL,
    override_type character varying(255) NOT NULL,
    start_time time(0) without time zone,
    end_time time(0) without time zone,
    reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT override_type_check CHECK (((override_type)::text = ANY ((ARRAY['unavailable'::character varying, 'custom_hours'::character varying, 'available'::character varying])::text[])))
);


--
-- Name: availability_overrides_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.availability_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: availability_overrides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.availability_overrides_id_seq OWNED BY public.availability_overrides.id;


--
-- Name: provider_calendar_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_calendar_events (
    id bigint NOT NULL,
    uid text NOT NULL,
    calendar_integration_id bigint NOT NULL,
    provider_event_id text,
    start_at timestamp(6) without time zone,
    end_at timestamp(6) without time zone,
    all_day boolean DEFAULT false NOT NULL,
    location text,
    description text,
    attendees jsonb[] DEFAULT ARRAY[]::jsonb[],
    recurrence_rule text,
    recurring_event_id text,
    status character varying(255) DEFAULT 'confirmed'::character varying NOT NULL,
    etag text,
    synced_at timestamp(6) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    provider character varying(255) NOT NULL,
    provider_calendar_id text NOT NULL,
    summary text,
    visibility character varying(255),
    colour character varying(255),
    start_date date,
    end_date date,
    timezone character varying(255),
    transparency character varying(255) DEFAULT 'opaque'::character varying NOT NULL,
    organiser jsonb,
    recurrence_exceptions date[] DEFAULT ARRAY[]::date[],
    attachments jsonb[] DEFAULT ARRAY[]::jsonb[],
    links jsonb[] DEFAULT ARRAY[]::jsonb[],
    reminders jsonb[] DEFAULT ARRAY[]::jsonb[],
    provider_updated_at timestamp without time zone,
    provider_metadata jsonb DEFAULT '{}'::jsonb,
    created_by_tymeslot boolean DEFAULT false NOT NULL,
    ical_sequence integer DEFAULT 0 NOT NULL,
    last_notified_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    video_integration_id integer,
    video_link text,
    raw_ical text,
    sync_state character varying(255) DEFAULT 'synced'::character varying NOT NULL,
    sync_attempts integer DEFAULT 0 NOT NULL,
    sync_last_attempt_at timestamp without time zone,
    sync_last_error text,
    CONSTRAINT provider_calendar_events_status_check CHECK (((status IS NULL) OR ((status)::text = ANY ((ARRAY['confirmed'::character varying, 'tentative'::character varying, 'cancelled'::character varying, 'declined'::character varying])::text[])))),
    CONSTRAINT provider_calendar_events_transparency_check CHECK (((transparency IS NULL) OR ((transparency)::text = ANY ((ARRAY['opaque'::character varying, 'transparent'::character varying])::text[]))))
);


--
-- Name: calendar_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendar_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendar_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendar_events_id_seq OWNED BY public.provider_calendar_events.id;


--
-- Name: calendar_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendar_integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    provider character varying(255) DEFAULT 'radicale'::character varying NOT NULL,
    base_url character varying(255) NOT NULL,
    username_encrypted bytea,
    password_encrypted bytea,
    calendar_paths character varying(255)[] DEFAULT ARRAY[]::character varying[],
    verify_ssl boolean DEFAULT true,
    is_active boolean DEFAULT true,
    last_sync_at timestamp(0) without time zone,
    sync_error text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    access_token_encrypted bytea,
    refresh_token_encrypted bytea,
    token_expires_at timestamp(0) without time zone,
    oauth_scope text,
    calendar_list jsonb[] DEFAULT ARRAY[]::jsonb[],
    default_booking_calendar_id character varying(255),
    provider_account_id character varying(255),
    provider_account_email character varying(255),
    google_channel_id character varying(255),
    google_channel_resource_id character varying(255),
    google_channel_expires_at timestamp(0) without time zone,
    google_channel_secret character varying(255),
    google_sync_token character varying(255),
    last_google_notification_at timestamp(0) without time zone,
    graph_subscription_id character varying(255),
    graph_subscription_expires_at timestamp(0) without time zone,
    graph_client_state character varying(255),
    graph_delta_link text,
    last_outlook_notification_at timestamp(0) without time zone,
    caldav_sync_tier integer,
    caldav_sync_token character varying(255),
    last_external_sync_at timestamp(0) without time zone,
    last_full_sync_at timestamp(0) without time zone,
    needs_reauth boolean DEFAULT false NOT NULL,
    CONSTRAINT calendar_integrations_provider_check CHECK (((provider)::text = ANY ((ARRAY['caldav'::character varying, 'radicale'::character varying, 'nextcloud'::character varying, 'zimbra'::character varying, 'mailbox_org'::character varying, 'baikal'::character varying, 'google'::character varying, 'outlook'::character varying, 'demo'::character varying, 'debug'::character varying])::text[])))
);


--
-- Name: calendar_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendar_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendar_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendar_integrations_id_seq OWNED BY public.calendar_integrations.id;


--
-- Name: calendar_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendar_preferences (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    default_view character varying(255) DEFAULT 'week'::character varying NOT NULL,
    hidden_integration_ids bigint[] DEFAULT ARRAY[]::bigint[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    week_start_day character varying(255) DEFAULT 'monday'::character varying NOT NULL,
    time_format character varying(255) DEFAULT '12h'::character varying NOT NULL,
    show_week_numbers boolean DEFAULT false NOT NULL,
    show_weekends boolean DEFAULT true NOT NULL
);


--
-- Name: calendar_preferences_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendar_preferences_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendar_preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendar_preferences_id_seq OWNED BY public.calendar_preferences.id;


--
-- Name: disputes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.disputes (
    id uuid NOT NULL,
    stripe_dispute_id character varying(255) NOT NULL,
    user_id bigint NOT NULL,
    charge_id character varying(255) NOT NULL,
    amount integer NOT NULL,
    currency character varying(255) NOT NULL,
    reason character varying(255),
    status character varying(255) NOT NULL,
    evidence_due_by timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_announcement_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_announcement_deliveries (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    announcement_key character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    delivered_at timestamp(0) without time zone,
    skip_reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_announcement_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_announcement_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_announcement_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_announcement_deliveries_id_seq OWNED BY public.email_announcement_deliveries.id;


--
-- Name: email_announcement_dispatches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_announcement_dispatches (
    id bigint NOT NULL,
    announcement_key character varying(255) NOT NULL,
    dispatched_at timestamp(0) without time zone NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_announcement_dispatches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_announcement_dispatches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_announcement_dispatches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_announcement_dispatches_id_seq OWNED BY public.email_announcement_dispatches.id;


--
-- Name: integration_health_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_health_states (
    id bigint NOT NULL,
    integration_type character varying(255) NOT NULL,
    integration_id bigint NOT NULL,
    user_id bigint NOT NULL,
    status character varying(255) DEFAULT 'healthy'::character varying NOT NULL,
    failures integer DEFAULT 0 NOT NULL,
    successes integer DEFAULT 0 NOT NULL,
    backoff_ms integer DEFAULT 1800000 NOT NULL,
    last_check_at timestamp without time zone,
    last_error_class character varying(255),
    became_unhealthy_at timestamp without time zone,
    notification_sent_at timestamp without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    consecutive_hard_failures integer DEFAULT 0 NOT NULL
);


--
-- Name: integration_health_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_health_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_health_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_health_states_id_seq OWNED BY public.integration_health_states.id;


--
-- Name: legal_acceptances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_acceptances (
    id uuid NOT NULL,
    user_id bigint NOT NULL,
    document_id bigint NOT NULL,
    accepted_at timestamp(0) without time zone NOT NULL,
    ip_address text,
    user_agent text
);


--
-- Name: legal_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_documents (
    id bigint NOT NULL,
    type character varying(255) NOT NULL,
    version character varying(255) NOT NULL,
    url character varying(255) NOT NULL,
    effective_at timestamp(0) without time zone NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT legal_documents_type_check CHECK (((type)::text = ANY ((ARRAY['terms'::character varying, 'privacy'::character varying])::text[])))
);


--
-- Name: legal_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.legal_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: legal_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.legal_documents_id_seq OWNED BY public.legal_documents.id;


--
-- Name: meeting_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meeting_types (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    duration_minutes integer NOT NULL,
    icon character varying(255),
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    allow_video boolean DEFAULT true NOT NULL,
    video_integration_id bigint,
    calendar_integration_id bigint,
    target_calendar_id character varying(255),
    reminder_config jsonb[],
    custom_fields jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL
);


--
-- Name: meeting_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.meeting_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: meeting_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.meeting_types_id_seq OWNED BY public.meeting_types.id;


--
-- Name: meetings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meetings (
    id uuid NOT NULL,
    uid character varying(255) NOT NULL,
    title character varying(255) NOT NULL,
    summary character varying(255),
    description text,
    start_time timestamp(0) without time zone NOT NULL,
    end_time timestamp(0) without time zone NOT NULL,
    duration integer,
    location character varying(255),
    meeting_type character varying(255),
    organizer_name character varying(255) NOT NULL,
    organizer_email character varying(255) NOT NULL,
    organizer_title character varying(255),
    attendee_name character varying(255) NOT NULL,
    attendee_email character varying(255) NOT NULL,
    attendee_message text,
    attendee_phone character varying(255),
    attendee_company character varying(255),
    view_url character varying(1000),
    reschedule_url character varying(1000),
    cancel_url character varying(1000),
    meeting_url character varying(1000),
    reminder_time character varying(255),
    default_reminder_time character varying(255),
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    organizer_email_sent boolean DEFAULT false NOT NULL,
    attendee_email_sent boolean DEFAULT false NOT NULL,
    reminder_email_sent boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    video_room_id character varying(255),
    organizer_video_url character varying(1000),
    attendee_video_url character varying(1000),
    video_room_enabled boolean DEFAULT false,
    video_room_created_at timestamp(0) without time zone,
    video_room_expires_at timestamp(0) without time zone,
    attendee_timezone character varying(255),
    cancelled_at timestamp(0) without time zone,
    cancellation_reason text,
    calendar_integration_id bigint,
    calendar_path character varying(255),
    organizer_user_id bigint,
    video_integration_id bigint,
    meeting_type_id bigint,
    reminders jsonb[],
    reminders_sent jsonb[],
    attendee_locale character varying(10) DEFAULT 'en'::character varying NOT NULL,
    calendar_sync_status character varying(255),
    calendar_sync_status_dismissed_at timestamp(0) without time zone,
    provider_event_id character varying(255),
    ical_sequence integer DEFAULT 0 NOT NULL,
    last_notified_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    custom_fields_snapshot jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    custom_field_answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    utm_source character varying(255),
    utm_medium character varying(255),
    utm_campaign character varying(255),
    utm_content character varying(255),
    utm_term character varying(255),
    referrer_host character varying(255),
    tracking_params jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: COLUMN meetings.video_room_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.video_room_id IS 'MiroTalk room ID extracted from meeting URL';


--
-- Name: COLUMN meetings.organizer_video_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.organizer_video_url IS 'Secure video join URL for the organizer';


--
-- Name: COLUMN meetings.attendee_video_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.attendee_video_url IS 'Secure video join URL for the attendee';


--
-- Name: COLUMN meetings.video_room_enabled; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.video_room_enabled IS 'Whether video room is enabled for this meeting';


--
-- Name: COLUMN meetings.video_room_created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.video_room_created_at IS 'When the video room was created';


--
-- Name: COLUMN meetings.video_room_expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.meetings.video_room_expires_at IS 'When video room access expires';


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '14';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: payment_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_transactions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    amount integer NOT NULL,
    status character varying(255) NOT NULL,
    stripe_id character varying(255),
    stripe_customer_id character varying(255),
    product_identifier character varying(255),
    subscription_id character varying(255),
    subscription_period character varying(255),
    tax_amount integer,
    tax_rate numeric(5,2),
    discount_amount integer,
    tax_id character varying(255),
    is_eu_business boolean DEFAULT false,
    country_code character varying(2),
    billing_address jsonb,
    payment_method character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: payment_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payment_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payment_transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payment_transactions_id_seq OWNED BY public.payment_transactions.id;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    timezone character varying(255) DEFAULT NULL::character varying,
    buffer_minutes integer DEFAULT 15,
    advance_booking_days integer DEFAULT 90,
    min_advance_hours integer DEFAULT 3,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    username character varying(255),
    avatar character varying(255),
    full_name character varying(255),
    booking_theme character varying(255) DEFAULT 'theme1'::character varying,
    has_custom_theme boolean DEFAULT false NOT NULL,
    primary_calendar_integration_id bigint,
    allowed_embed_domains character varying(255)[] DEFAULT ARRAY[]::character varying[]
);


--
-- Name: profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profiles_id_seq OWNED BY public.profiles.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: schema_migrations_saas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations_saas (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: slack_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_deliveries (
    id uuid NOT NULL,
    integration_id bigint NOT NULL,
    event_type character varying(255) NOT NULL,
    meeting_id character varying(255),
    message_blocks jsonb,
    response_status integer,
    response_body text,
    error_message text,
    delivered_at timestamp without time zone,
    attempt_count integer DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: slack_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    app_mode character varying(255) NOT NULL,
    bot_token_encrypted bytea,
    team_id character varying(255),
    team_name character varying(255),
    channel_id character varying(255),
    channel_name character varying(255),
    authed_user_id character varying(255),
    scope character varying(255),
    link_token character varying(255),
    webhook_url_encrypted bytea,
    webhook_channel_hint character varying(255),
    events character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_triggered_at timestamp without time zone,
    failure_count integer DEFAULT 0 NOT NULL,
    disabled_at timestamp without time zone,
    disabled_reason character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT app_mode_must_be_valid CHECK (((app_mode)::text = ANY ((ARRAY['oauth'::character varying, 'webhook_url'::character varying])::text[])))
);


--
-- Name: slack_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.slack_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: slack_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.slack_integrations_id_seq OWNED BY public.slack_integrations.id;


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    stripe_subscription_id character varying(255) NOT NULL,
    stripe_customer_id character varying(255) NOT NULL,
    plan character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    current_period_start timestamp(0) without time zone,
    current_period_end timestamp(0) without time zone,
    cancel_at_period_end boolean DEFAULT false,
    canceled_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    trial_started_at timestamp(0) without time zone,
    trial_ends_at timestamp(0) without time zone,
    trial_period_days integer DEFAULT 7,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    billing_interval character varying(255)
);


--
-- Name: subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subscriptions_id_seq OWNED BY public.subscriptions.id;


--
-- Name: telegram_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_deliveries (
    id uuid NOT NULL,
    integration_id bigint NOT NULL,
    event_type character varying(255) NOT NULL,
    meeting_id uuid,
    message_text text,
    response_status integer,
    response_body character varying(2000),
    error_message character varying(255),
    delivered_at timestamp(0) without time zone,
    attempt_count integer DEFAULT 1,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: telegram_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    bot_mode character varying(255) DEFAULT 'own'::character varying NOT NULL,
    bot_token_encrypted bytea,
    chat_id character varying(255),
    events character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_triggered_at timestamp(0) without time zone,
    failure_count integer DEFAULT 0 NOT NULL,
    disabled_at timestamp(0) without time zone,
    disabled_reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    link_token character varying(255)
);


--
-- Name: telegram_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.telegram_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: telegram_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.telegram_integrations_id_seq OWNED BY public.telegram_integrations.id;


--
-- Name: theme_customizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_customizations (
    id bigint NOT NULL,
    profile_id bigint NOT NULL,
    color_scheme character varying(255) DEFAULT 'default'::character varying NOT NULL,
    background_type character varying(255) DEFAULT 'gradient'::character varying NOT NULL,
    background_value text,
    background_image_path character varying(255),
    background_video_path character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    theme_id character varying(255) DEFAULT '1'::character varying NOT NULL,
    video_processing character varying(255),
    custom_palette_seed character varying(255)
);


--
-- Name: theme_customizations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.theme_customizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: theme_customizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.theme_customizations_id_seq OWNED BY public.theme_customizations.id;


--
-- Name: user_seen_announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_seen_announcements (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    announcement_key character varying(255) NOT NULL,
    seen_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_seen_announcements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_seen_announcements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_seen_announcements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_seen_announcements_id_seq OWNED BY public.user_seen_announcements.id;


--
-- Name: user_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_sessions_id_seq OWNED BY public.user_sessions.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255),
    verified_at timestamp(0) without time zone,
    verification_token character varying(255),
    verification_sent_at timestamp(0) without time zone,
    reset_sent_at timestamp(0) without time zone,
    name character varying(255),
    provider character varying(255),
    provider_uid character varying(255),
    provider_email character varying(255),
    provider_meta jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    onboarding_completed_at timestamp(0) without time zone,
    verification_token_used_at timestamp(0) without time zone,
    reset_token_used_at timestamp(0) without time zone,
    github_user_id character varying(255),
    google_user_id character varying(255),
    pending_email character varying(255),
    email_change_sent_at timestamp(0) without time zone,
    email_change_confirmed_at timestamp(0) without time zone,
    email_change_token_hash character varying(255),
    reset_token_hash character varying(255),
    signup_ip character varying(255),
    marketing_unsubscribed_at timestamp(0) without time zone,
    is_admin boolean DEFAULT false NOT NULL,
    dashboard_tour_seen_at timestamp(0) without time zone
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: video_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    provider character varying(255) DEFAULT 'mirotalk'::character varying NOT NULL,
    base_url character varying(255),
    api_key_encrypted bytea,
    is_active boolean DEFAULT true,
    is_default boolean DEFAULT false,
    settings jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    access_token_encrypted bytea,
    refresh_token_encrypted bytea,
    token_expires_at timestamp(0) without time zone,
    oauth_scope character varying(255),
    account_id_encrypted bytea,
    client_id_encrypted bytea,
    client_secret_encrypted bytea,
    tenant_id_encrypted bytea,
    teams_user_id_encrypted bytea,
    custom_meeting_url character varying(255),
    provider_account_id character varying(255),
    provider_account_email character varying(255),
    needs_reauth boolean DEFAULT false NOT NULL,
    sync_error text
);


--
-- Name: video_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.video_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: video_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.video_integrations_id_seq OWNED BY public.video_integrations.id;


--
-- Name: webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_deliveries (
    id uuid NOT NULL,
    webhook_id bigint NOT NULL,
    event_type character varying(255) NOT NULL,
    meeting_id uuid,
    payload jsonb NOT NULL,
    response_status integer,
    response_body text,
    error_message text,
    delivered_at timestamp(0) without time zone,
    attempt_count integer DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_events (
    id bigint NOT NULL,
    stripe_event_id character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    processed_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    payload jsonb
);


--
-- Name: webhook_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.webhook_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: webhook_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.webhook_events_id_seq OWNED BY public.webhook_events.id;


--
-- Name: webhooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhooks (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    url character varying(255) NOT NULL,
    events character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_triggered_at timestamp(0) without time zone,
    last_status character varying(255),
    failure_count integer DEFAULT 0 NOT NULL,
    disabled_at timestamp(0) without time zone,
    disabled_reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    webhook_token_encrypted bytea NOT NULL
);


--
-- Name: webhooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.webhooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: webhooks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.webhooks_id_seq OWNED BY public.webhooks.id;


--
-- Name: weekly_availability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weekly_availability (
    id bigint NOT NULL,
    profile_id bigint NOT NULL,
    day_of_week integer NOT NULL,
    is_available boolean DEFAULT false,
    start_time time(0) without time zone,
    end_time time(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: weekly_availability_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.weekly_availability_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: weekly_availability_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.weekly_availability_id_seq OWNED BY public.weekly_availability.id;


--
-- Name: analytics_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events ALTER COLUMN id SET DEFAULT nextval('public.analytics_events_id_seq'::regclass);


--
-- Name: app_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings ALTER COLUMN id SET DEFAULT nextval('public.app_settings_id_seq'::regclass);


--
-- Name: availability_breaks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_breaks ALTER COLUMN id SET DEFAULT nextval('public.availability_breaks_id_seq'::regclass);


--
-- Name: availability_overrides id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_overrides ALTER COLUMN id SET DEFAULT nextval('public.availability_overrides_id_seq'::regclass);


--
-- Name: calendar_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_integrations ALTER COLUMN id SET DEFAULT nextval('public.calendar_integrations_id_seq'::regclass);


--
-- Name: calendar_preferences id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_preferences ALTER COLUMN id SET DEFAULT nextval('public.calendar_preferences_id_seq'::regclass);


--
-- Name: email_announcement_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_announcement_deliveries ALTER COLUMN id SET DEFAULT nextval('public.email_announcement_deliveries_id_seq'::regclass);


--
-- Name: email_announcement_dispatches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_announcement_dispatches ALTER COLUMN id SET DEFAULT nextval('public.email_announcement_dispatches_id_seq'::regclass);


--
-- Name: integration_health_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_health_states ALTER COLUMN id SET DEFAULT nextval('public.integration_health_states_id_seq'::regclass);


--
-- Name: legal_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents ALTER COLUMN id SET DEFAULT nextval('public.legal_documents_id_seq'::regclass);


--
-- Name: meeting_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meeting_types ALTER COLUMN id SET DEFAULT nextval('public.meeting_types_id_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: payment_transactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transactions ALTER COLUMN id SET DEFAULT nextval('public.payment_transactions_id_seq'::regclass);


--
-- Name: profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles ALTER COLUMN id SET DEFAULT nextval('public.profiles_id_seq'::regclass);


--
-- Name: provider_calendar_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_calendar_events ALTER COLUMN id SET DEFAULT nextval('public.calendar_events_id_seq'::regclass);


--
-- Name: slack_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations ALTER COLUMN id SET DEFAULT nextval('public.slack_integrations_id_seq'::regclass);


--
-- Name: subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions ALTER COLUMN id SET DEFAULT nextval('public.subscriptions_id_seq'::regclass);


--
-- Name: telegram_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations ALTER COLUMN id SET DEFAULT nextval('public.telegram_integrations_id_seq'::regclass);


--
-- Name: theme_customizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_customizations ALTER COLUMN id SET DEFAULT nextval('public.theme_customizations_id_seq'::regclass);


--
-- Name: user_seen_announcements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_seen_announcements ALTER COLUMN id SET DEFAULT nextval('public.user_seen_announcements_id_seq'::regclass);


--
-- Name: user_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions ALTER COLUMN id SET DEFAULT nextval('public.user_sessions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: video_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_integrations ALTER COLUMN id SET DEFAULT nextval('public.video_integrations_id_seq'::regclass);


--
-- Name: webhook_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_events ALTER COLUMN id SET DEFAULT nextval('public.webhook_events_id_seq'::regclass);


--
-- Name: webhooks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhooks ALTER COLUMN id SET DEFAULT nextval('public.webhooks_id_seq'::regclass);


--
-- Name: weekly_availability id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_availability ALTER COLUMN id SET DEFAULT nextval('public.weekly_availability_id_seq'::regclass);


--
-- Name: analytics_events analytics_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events
    ADD CONSTRAINT analytics_events_pkey PRIMARY KEY (id);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (id);


--
-- Name: availability_breaks availability_breaks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_breaks
    ADD CONSTRAINT availability_breaks_pkey PRIMARY KEY (id);


--
-- Name: availability_overrides availability_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_overrides
    ADD CONSTRAINT availability_overrides_pkey PRIMARY KEY (id);


--
-- Name: calendar_integrations calendar_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_integrations
    ADD CONSTRAINT calendar_integrations_pkey PRIMARY KEY (id);


--
-- Name: calendar_preferences calendar_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_preferences
    ADD CONSTRAINT calendar_preferences_pkey PRIMARY KEY (id);


--
-- Name: disputes disputes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disputes
    ADD CONSTRAINT disputes_pkey PRIMARY KEY (id);


--
-- Name: email_announcement_deliveries email_announcement_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_announcement_deliveries
    ADD CONSTRAINT email_announcement_deliveries_pkey PRIMARY KEY (id);


--
-- Name: email_announcement_dispatches email_announcement_dispatches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_announcement_dispatches
    ADD CONSTRAINT email_announcement_dispatches_pkey PRIMARY KEY (id);


--
-- Name: integration_health_states integration_health_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_health_states
    ADD CONSTRAINT integration_health_states_pkey PRIMARY KEY (id);


--
-- Name: legal_acceptances legal_acceptances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT legal_acceptances_pkey PRIMARY KEY (id);


--
-- Name: legal_documents legal_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT legal_documents_pkey PRIMARY KEY (id);


--
-- Name: meeting_types meeting_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meeting_types
    ADD CONSTRAINT meeting_types_pkey PRIMARY KEY (id);


--
-- Name: meetings meetings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: payment_transactions payment_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transactions
    ADD CONSTRAINT payment_transactions_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: provider_calendar_events provider_calendar_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_calendar_events
    ADD CONSTRAINT provider_calendar_events_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: schema_migrations_saas schema_migrations_saas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations_saas
    ADD CONSTRAINT schema_migrations_saas_pkey PRIMARY KEY (version);


--
-- Name: slack_deliveries slack_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_deliveries
    ADD CONSTRAINT slack_deliveries_pkey PRIMARY KEY (id);


--
-- Name: slack_integrations slack_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations
    ADD CONSTRAINT slack_integrations_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: telegram_deliveries telegram_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_deliveries
    ADD CONSTRAINT telegram_deliveries_pkey PRIMARY KEY (id);


--
-- Name: telegram_integrations telegram_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_pkey PRIMARY KEY (id);


--
-- Name: theme_customizations theme_customizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_customizations
    ADD CONSTRAINT theme_customizations_pkey PRIMARY KEY (id);


--
-- Name: user_seen_announcements user_seen_announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_seen_announcements
    ADD CONSTRAINT user_seen_announcements_pkey PRIMARY KEY (id);


--
-- Name: user_sessions user_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: video_integrations video_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_integrations
    ADD CONSTRAINT video_integrations_pkey PRIMARY KEY (id);


--
-- Name: webhook_deliveries webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: webhooks webhooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhooks
    ADD CONSTRAINT webhooks_pkey PRIMARY KEY (id);


--
-- Name: weekly_availability weekly_availability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_availability
    ADD CONSTRAINT weekly_availability_pkey PRIMARY KEY (id);


--
-- Name: analytics_events_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_inserted_at_index ON public.analytics_events USING btree (inserted_at);


--
-- Name: analytics_events_meeting_type_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_meeting_type_id_inserted_at_index ON public.analytics_events USING btree (meeting_type_id, inserted_at);


--
-- Name: analytics_events_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_user_id_inserted_at_index ON public.analytics_events USING btree (user_id, inserted_at);


--
-- Name: analytics_events_visitor_hash_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX analytics_events_visitor_hash_inserted_at_index ON public.analytics_events USING btree (visitor_hash, inserted_at);


--
-- Name: availability_breaks_weekly_availability_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX availability_breaks_weekly_availability_id_index ON public.availability_breaks USING btree (weekly_availability_id);


--
-- Name: availability_breaks_weekly_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX availability_breaks_weekly_start_time_index ON public.availability_breaks USING btree (weekly_availability_id, start_time);


--
-- Name: availability_overrides_profile_id_date_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX availability_overrides_profile_id_date_index ON public.availability_overrides USING btree (profile_id, date);


--
-- Name: availability_overrides_profile_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX availability_overrides_profile_id_index ON public.availability_overrides USING btree (profile_id);


--
-- Name: calendar_integrations_default_booking_calendar_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_default_booking_calendar_id_index ON public.calendar_integrations USING btree (default_booking_calendar_id);


--
-- Name: calendar_integrations_google_channel_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_google_channel_id_index ON public.calendar_integrations USING btree (google_channel_id);


--
-- Name: calendar_integrations_graph_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_graph_subscription_id_index ON public.calendar_integrations USING btree (graph_subscription_id);


--
-- Name: calendar_integrations_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_is_active_index ON public.calendar_integrations USING btree (is_active);


--
-- Name: calendar_integrations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_user_id_index ON public.calendar_integrations USING btree (user_id);


--
-- Name: calendar_integrations_user_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_integrations_user_provider_index ON public.calendar_integrations USING btree (user_id, provider);


--
-- Name: calendar_preferences_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX calendar_preferences_user_id_index ON public.calendar_preferences USING btree (user_id);


--
-- Name: disputes_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX disputes_status_index ON public.disputes USING btree (status);


--
-- Name: disputes_stripe_dispute_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX disputes_stripe_dispute_id_index ON public.disputes USING btree (stripe_dispute_id);


--
-- Name: disputes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX disputes_user_id_index ON public.disputes USING btree (user_id);


--
-- Name: email_announcement_deliveries_announcement_key_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_announcement_deliveries_announcement_key_user_id_index ON public.email_announcement_deliveries USING btree (announcement_key, user_id);


--
-- Name: email_announcement_deliveries_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_announcement_deliveries_user_id_index ON public.email_announcement_deliveries USING btree (user_id);


--
-- Name: email_announcement_dispatches_announcement_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_announcement_dispatches_announcement_key_index ON public.email_announcement_dispatches USING btree (announcement_key);


--
-- Name: idx_meetings_attendee_email_start_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meetings_attendee_email_start_time ON public.meetings USING btree (attendee_email, start_time);


--
-- Name: idx_meetings_organizer_email_start_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meetings_organizer_email_start_time ON public.meetings USING btree (organizer_email, start_time);


--
-- Name: idx_meetings_reminders_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meetings_reminders_due ON public.meetings USING btree (start_time) WHERE (((status)::text = 'confirmed'::text) AND (reminder_email_sent = false));


--
-- Name: idx_oban_jobs_args_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oban_jobs_args_gin ON public.oban_jobs USING gin (args);


--
-- Name: idx_oban_jobs_monitoring; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oban_jobs_monitoring ON public.oban_jobs USING btree (state, queue, inserted_at) WHERE (state = ANY (ARRAY['available'::public.oban_job_state, 'retryable'::public.oban_job_state]));


--
-- Name: idx_oban_jobs_scheduled_monitoring; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oban_jobs_scheduled_monitoring ON public.oban_jobs USING btree (state, queue, scheduled_at, inserted_at) WHERE (state = 'retryable'::public.oban_job_state);


--
-- Name: integration_health_states_integration_type_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX integration_health_states_integration_type_integration_id_index ON public.integration_health_states USING btree (integration_type, integration_id);


--
-- Name: integration_health_states_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_health_states_user_id_index ON public.integration_health_states USING btree (user_id);


--
-- Name: integration_health_states_user_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_health_states_user_id_status_index ON public.integration_health_states USING btree (user_id, status);


--
-- Name: legal_acceptances_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX legal_acceptances_document_id_index ON public.legal_acceptances USING btree (document_id);


--
-- Name: legal_acceptances_user_id_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX legal_acceptances_user_id_document_id_index ON public.legal_acceptances USING btree (user_id, document_id);


--
-- Name: legal_documents_one_current_per_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX legal_documents_one_current_per_type ON public.legal_documents USING btree (type) WHERE (is_current = true);


--
-- Name: legal_documents_type_is_current_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX legal_documents_type_is_current_index ON public.legal_documents USING btree (type, is_current);


--
-- Name: legal_documents_type_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX legal_documents_type_version_index ON public.legal_documents USING btree (type, version);


--
-- Name: meeting_types_calendar_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meeting_types_calendar_integration_id_index ON public.meeting_types USING btree (calendar_integration_id);


--
-- Name: meeting_types_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meeting_types_user_id_index ON public.meeting_types USING btree (user_id);


--
-- Name: meeting_types_user_id_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meeting_types_user_id_is_active_index ON public.meeting_types USING btree (user_id, is_active);


--
-- Name: meeting_types_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX meeting_types_user_id_name_index ON public.meeting_types USING btree (user_id, name);


--
-- Name: meeting_types_video_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meeting_types_video_integration_id_index ON public.meeting_types USING btree (video_integration_id);


--
-- Name: meetings_attendee_email_end_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_email_end_time_index ON public.meetings USING btree (attendee_email, end_time);


--
-- Name: meetings_attendee_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_email_index ON public.meetings USING btree (attendee_email);


--
-- Name: meetings_attendee_email_sent_organizer_email_sent_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_email_sent_organizer_email_sent_index ON public.meetings USING btree (attendee_email_sent, organizer_email_sent);


--
-- Name: meetings_attendee_email_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_email_start_time_index ON public.meetings USING btree (attendee_email, start_time);


--
-- Name: meetings_attendee_email_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_email_status_index ON public.meetings USING btree (attendee_email, status);


--
-- Name: meetings_attendee_status_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_attendee_status_start_time_index ON public.meetings USING btree (attendee_email, status, start_time);


--
-- Name: meetings_calendar_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_calendar_integration_id_index ON public.meetings USING btree (calendar_integration_id);


--
-- Name: meetings_calendar_integration_id_provider_event_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_calendar_integration_id_provider_event_id_index ON public.meetings USING btree (calendar_integration_id, provider_event_id);


--
-- Name: meetings_calendar_integration_id_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_calendar_integration_id_uid_index ON public.meetings USING btree (calendar_integration_id, uid);


--
-- Name: meetings_end_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_end_time_index ON public.meetings USING btree (end_time);


--
-- Name: meetings_meeting_type_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_meeting_type_id_index ON public.meetings USING btree (meeting_type_id);


--
-- Name: meetings_need_video_room_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_need_video_room_index ON public.meetings USING btree (status, video_room_id) WHERE (((status)::text = 'confirmed'::text) AND (video_room_id IS NULL));


--
-- Name: meetings_organizer_email_end_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_email_end_time_index ON public.meetings USING btree (organizer_email, end_time);


--
-- Name: meetings_organizer_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_email_index ON public.meetings USING btree (organizer_email);


--
-- Name: meetings_organizer_email_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_email_start_time_index ON public.meetings USING btree (organizer_email, start_time);


--
-- Name: meetings_organizer_email_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_email_status_index ON public.meetings USING btree (organizer_email, status);


--
-- Name: meetings_organizer_status_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_status_start_time_index ON public.meetings USING btree (organizer_email, status, start_time);


--
-- Name: meetings_organizer_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_organizer_user_id_index ON public.meetings USING btree (organizer_user_id);


--
-- Name: meetings_reminder_email_sent_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_reminder_email_sent_start_time_index ON public.meetings USING btree (reminder_email_sent, start_time);


--
-- Name: meetings_start_time_end_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_start_time_end_time_index ON public.meetings USING btree (start_time, end_time);


--
-- Name: meetings_start_time_end_time_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_start_time_end_time_status_index ON public.meetings USING btree (start_time, end_time, status);


--
-- Name: meetings_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_start_time_index ON public.meetings USING btree (start_time);


--
-- Name: meetings_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_status_index ON public.meetings USING btree (status);


--
-- Name: meetings_status_start_time_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_status_start_time_index ON public.meetings USING btree (status, start_time);


--
-- Name: meetings_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX meetings_uid_index ON public.meetings USING btree (uid);


--
-- Name: meetings_utm_campaign_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_utm_campaign_index ON public.meetings USING btree (utm_campaign);


--
-- Name: meetings_utm_source_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_utm_source_index ON public.meetings USING btree (utm_source);


--
-- Name: meetings_video_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_video_integration_id_index ON public.meetings USING btree (video_integration_id);


--
-- Name: meetings_video_room_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_video_room_enabled_index ON public.meetings USING btree (video_room_enabled);


--
-- Name: meetings_video_room_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_video_room_expires_at_index ON public.meetings USING btree (video_room_expires_at);


--
-- Name: meetings_video_room_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meetings_video_room_id_index ON public.meetings USING btree (video_room_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: one_default_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX one_default_per_user ON public.video_integrations USING btree (user_id, is_default) WHERE (is_default = true);


--
-- Name: payment_transactions_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_transactions_inserted_at_index ON public.payment_transactions USING btree (inserted_at);


--
-- Name: payment_transactions_product_identifier_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_transactions_product_identifier_index ON public.payment_transactions USING btree (product_identifier);


--
-- Name: payment_transactions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_transactions_status_index ON public.payment_transactions USING btree (status);


--
-- Name: payment_transactions_stripe_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payment_transactions_stripe_id_index ON public.payment_transactions USING btree (stripe_id);


--
-- Name: payment_transactions_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_transactions_subscription_id_index ON public.payment_transactions USING btree (subscription_id);


--
-- Name: payment_transactions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_transactions_user_id_index ON public.payment_transactions USING btree (user_id);


--
-- Name: profiles_allowed_embed_domains_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_allowed_embed_domains_index ON public.profiles USING gin (allowed_embed_domains);


--
-- Name: profiles_has_custom_theme_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_has_custom_theme_index ON public.profiles USING btree (has_custom_theme);


--
-- Name: profiles_primary_calendar_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_primary_calendar_integration_id_index ON public.profiles USING btree (primary_calendar_integration_id);


--
-- Name: profiles_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_user_id_index ON public.profiles USING btree (user_id);


--
-- Name: profiles_username_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_username_index ON public.profiles USING btree (username);


--
-- Name: provider_calendar_events_calendar_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_calendar_events_calendar_integration_id_index ON public.provider_calendar_events USING btree (calendar_integration_id);


--
-- Name: provider_calendar_events_calendar_integration_id_start_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_calendar_events_calendar_integration_id_start_at_index ON public.provider_calendar_events USING btree (calendar_integration_id, start_at);


--
-- Name: provider_calendar_events_calendar_integration_id_start_date_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_calendar_events_calendar_integration_id_start_date_ind ON public.provider_calendar_events USING btree (calendar_integration_id, start_date);


--
-- Name: provider_calendar_events_calendar_integration_id_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX provider_calendar_events_calendar_integration_id_uid_index ON public.provider_calendar_events USING btree (calendar_integration_id, uid);


--
-- Name: provider_calendar_events_pending_sync_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_calendar_events_pending_sync_idx ON public.provider_calendar_events USING btree (calendar_integration_id, sync_state) WHERE ((sync_state)::text <> 'synced'::text);


--
-- Name: provider_calendar_events_video_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_calendar_events_video_integration_id_index ON public.provider_calendar_events USING btree (video_integration_id);


--
-- Name: slack_deliveries_event_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_deliveries_event_type_index ON public.slack_deliveries USING btree (event_type);


--
-- Name: slack_deliveries_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_deliveries_inserted_at_index ON public.slack_deliveries USING btree (inserted_at);


--
-- Name: slack_deliveries_integration_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_deliveries_integration_id_index ON public.slack_deliveries USING btree (integration_id);


--
-- Name: slack_deliveries_integration_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_deliveries_integration_id_inserted_at_index ON public.slack_deliveries USING btree (integration_id, inserted_at);


--
-- Name: slack_integrations_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_integrations_is_active_index ON public.slack_integrations USING btree (is_active);


--
-- Name: slack_integrations_link_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_integrations_link_token_index ON public.slack_integrations USING btree (link_token) WHERE (link_token IS NOT NULL);


--
-- Name: slack_integrations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_integrations_user_id_index ON public.slack_integrations USING btree (user_id);


--
-- Name: slack_integrations_user_team_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_integrations_user_team_unique_index ON public.slack_integrations USING btree (user_id, team_id) WHERE (team_id IS NOT NULL);


--
-- Name: subscriptions_plan_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_plan_index ON public.subscriptions USING btree (plan);


--
-- Name: subscriptions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_status_index ON public.subscriptions USING btree (status);


--
-- Name: subscriptions_stripe_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_stripe_subscription_id_index ON public.subscriptions USING btree (stripe_subscription_id);


--
-- Name: subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_user_id_index ON public.subscriptions USING btree (user_id);


--
-- Name: telegram_deliveries_integration_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telegram_deliveries_integration_id_inserted_at_index ON public.telegram_deliveries USING btree (integration_id, inserted_at);


--
-- Name: telegram_integrations_link_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX telegram_integrations_link_token_index ON public.telegram_integrations USING btree (link_token) WHERE (link_token IS NOT NULL);


--
-- Name: telegram_integrations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telegram_integrations_user_id_index ON public.telegram_integrations USING btree (user_id);


--
-- Name: telegram_integrations_user_id_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telegram_integrations_user_id_is_active_index ON public.telegram_integrations USING btree (user_id, is_active) WHERE (is_active = true);


--
-- Name: theme_customizations_background_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX theme_customizations_background_type_index ON public.theme_customizations USING btree (background_type);


--
-- Name: theme_customizations_color_scheme_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX theme_customizations_color_scheme_index ON public.theme_customizations USING btree (color_scheme);


--
-- Name: theme_customizations_profile_id_theme_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX theme_customizations_profile_id_theme_id_index ON public.theme_customizations USING btree (profile_id, theme_id);


--
-- Name: theme_customizations_theme_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX theme_customizations_theme_id_index ON public.theme_customizations USING btree (theme_id);


--
-- Name: unique_active_calendar_account_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_active_calendar_account_per_user ON public.calendar_integrations USING btree (user_id, provider, provider_account_id) WHERE ((is_active = true) AND (provider_account_id IS NOT NULL));


--
-- Name: unique_active_calendar_null_account_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_active_calendar_null_account_per_user ON public.calendar_integrations USING btree (user_id, provider) WHERE ((is_active = true) AND (provider_account_id IS NULL));


--
-- Name: unique_active_video_account_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_active_video_account_per_user ON public.video_integrations USING btree (user_id, provider, provider_account_id) WHERE ((is_active = true) AND (provider_account_id IS NOT NULL));


--
-- Name: unique_active_video_null_account_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_active_video_null_account_per_user ON public.video_integrations USING btree (user_id, provider) WHERE ((is_active = true) AND (provider_account_id IS NULL));


--
-- Name: unique_confirmed_meeting_per_organizer_at_time; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_confirmed_meeting_per_organizer_at_time ON public.meetings USING btree (organizer_user_id, start_time) WHERE (((status)::text = 'confirmed'::text) AND (organizer_user_id IS NOT NULL));


--
-- Name: unique_pending_transaction_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_pending_transaction_per_user ON public.payment_transactions USING btree (user_id) WHERE ((status)::text = 'pending'::text);


--
-- Name: user_seen_announcements_user_id_announcement_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_seen_announcements_user_id_announcement_key_index ON public.user_seen_announcements USING btree (user_id, announcement_key);


--
-- Name: user_seen_announcements_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_seen_announcements_user_id_index ON public.user_seen_announcements USING btree (user_id);


--
-- Name: user_sessions_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_sessions_token_index ON public.user_sessions USING btree (token);


--
-- Name: user_sessions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_sessions_user_id_index ON public.user_sessions USING btree (user_id);


--
-- Name: users_email_change_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_change_token_hash_index ON public.users USING btree (email_change_token_hash);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_github_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_github_user_id_index ON public.users USING btree (github_user_id);


--
-- Name: users_google_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_google_user_id_index ON public.users USING btree (google_user_id);


--
-- Name: users_is_admin_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_is_admin_index ON public.users USING btree (is_admin) WHERE (is_admin = true);


--
-- Name: users_pending_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_pending_email_index ON public.users USING btree (pending_email);


--
-- Name: users_provider_provider_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_provider_provider_uid_index ON public.users USING btree (provider, provider_uid);


--
-- Name: users_reset_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_reset_token_hash_index ON public.users USING btree (reset_token_hash);


--
-- Name: users_verification_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_verification_token_index ON public.users USING btree (verification_token);


--
-- Name: video_integrations_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_integrations_provider_index ON public.video_integrations USING btree (provider);


--
-- Name: video_integrations_token_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_integrations_token_expires_at_index ON public.video_integrations USING btree (token_expires_at);


--
-- Name: video_integrations_user_default_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_integrations_user_default_active_index ON public.video_integrations USING btree (user_id, is_default, is_active);


--
-- Name: video_integrations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_integrations_user_id_index ON public.video_integrations USING btree (user_id);


--
-- Name: webhook_deliveries_event_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_deliveries_event_type_index ON public.webhook_deliveries USING btree (event_type);


--
-- Name: webhook_deliveries_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_deliveries_inserted_at_index ON public.webhook_deliveries USING btree (inserted_at);


--
-- Name: webhook_deliveries_meeting_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_deliveries_meeting_id_index ON public.webhook_deliveries USING btree (meeting_id);


--
-- Name: webhook_deliveries_retention_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_deliveries_retention_idx ON public.webhook_deliveries USING btree (inserted_at);


--
-- Name: webhook_deliveries_webhook_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_deliveries_webhook_id_index ON public.webhook_deliveries USING btree (webhook_id);


--
-- Name: webhook_events_event_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_events_event_type_index ON public.webhook_events USING btree (event_type);


--
-- Name: webhook_events_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_events_inserted_at_index ON public.webhook_events USING btree (inserted_at);


--
-- Name: webhook_events_stripe_event_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX webhook_events_stripe_event_id_index ON public.webhook_events USING btree (stripe_event_id);


--
-- Name: webhooks_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhooks_user_id_index ON public.webhooks USING btree (user_id);


--
-- Name: webhooks_user_id_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhooks_user_id_is_active_index ON public.webhooks USING btree (user_id, is_active);


--
-- Name: weekly_availability_profile_id_day_of_week_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX weekly_availability_profile_id_day_of_week_index ON public.weekly_availability USING btree (profile_id, day_of_week);


--
-- Name: weekly_availability_profile_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX weekly_availability_profile_id_index ON public.weekly_availability USING btree (profile_id);


--
-- Name: analytics_events analytics_events_meeting_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events
    ADD CONSTRAINT analytics_events_meeting_type_id_fkey FOREIGN KEY (meeting_type_id) REFERENCES public.meeting_types(id) ON DELETE SET NULL;


--
-- Name: analytics_events analytics_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_events
    ADD CONSTRAINT analytics_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: availability_breaks availability_breaks_weekly_availability_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_breaks
    ADD CONSTRAINT availability_breaks_weekly_availability_id_fkey FOREIGN KEY (weekly_availability_id) REFERENCES public.weekly_availability(id) ON DELETE CASCADE;


--
-- Name: availability_overrides availability_overrides_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.availability_overrides
    ADD CONSTRAINT availability_overrides_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: provider_calendar_events calendar_events_calendar_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_calendar_events
    ADD CONSTRAINT calendar_events_calendar_integration_id_fkey FOREIGN KEY (calendar_integration_id) REFERENCES public.calendar_integrations(id) ON DELETE CASCADE;


--
-- Name: calendar_integrations calendar_integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_integrations
    ADD CONSTRAINT calendar_integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: calendar_preferences calendar_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_preferences
    ADD CONSTRAINT calendar_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: integration_health_states integration_health_states_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_health_states
    ADD CONSTRAINT integration_health_states_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: legal_acceptances legal_acceptances_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT legal_acceptances_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.legal_documents(id);


--
-- Name: meeting_types meeting_types_calendar_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meeting_types
    ADD CONSTRAINT meeting_types_calendar_integration_id_fkey FOREIGN KEY (calendar_integration_id) REFERENCES public.calendar_integrations(id) ON DELETE SET NULL;


--
-- Name: meeting_types meeting_types_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meeting_types
    ADD CONSTRAINT meeting_types_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: meeting_types meeting_types_video_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meeting_types
    ADD CONSTRAINT meeting_types_video_integration_id_fkey FOREIGN KEY (video_integration_id) REFERENCES public.video_integrations(id) ON DELETE SET NULL;


--
-- Name: meetings meetings_calendar_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_calendar_integration_id_fkey FOREIGN KEY (calendar_integration_id) REFERENCES public.calendar_integrations(id) ON DELETE SET NULL;


--
-- Name: meetings meetings_meeting_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_meeting_type_id_fkey FOREIGN KEY (meeting_type_id) REFERENCES public.meeting_types(id) ON DELETE SET NULL;


--
-- Name: meetings meetings_organizer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_organizer_user_id_fkey FOREIGN KEY (organizer_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: meetings meetings_video_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_video_integration_id_fkey FOREIGN KEY (video_integration_id) REFERENCES public.video_integrations(id) ON DELETE SET NULL;


--
-- Name: payment_transactions payment_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transactions
    ADD CONSTRAINT payment_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_primary_calendar_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_primary_calendar_integration_id_fkey FOREIGN KEY (primary_calendar_integration_id) REFERENCES public.calendar_integrations(id) ON DELETE SET NULL;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: provider_calendar_events provider_calendar_events_video_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_calendar_events
    ADD CONSTRAINT provider_calendar_events_video_integration_id_fkey FOREIGN KEY (video_integration_id) REFERENCES public.video_integrations(id) ON DELETE SET NULL;


--
-- Name: slack_deliveries slack_deliveries_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_deliveries
    ADD CONSTRAINT slack_deliveries_integration_id_fkey FOREIGN KEY (integration_id) REFERENCES public.slack_integrations(id) ON DELETE CASCADE;


--
-- Name: slack_integrations slack_integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations
    ADD CONSTRAINT slack_integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: telegram_deliveries telegram_deliveries_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_deliveries
    ADD CONSTRAINT telegram_deliveries_integration_id_fkey FOREIGN KEY (integration_id) REFERENCES public.telegram_integrations(id) ON DELETE CASCADE;


--
-- Name: telegram_integrations telegram_integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: theme_customizations theme_customizations_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_customizations
    ADD CONSTRAINT theme_customizations_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: user_seen_announcements user_seen_announcements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_seen_announcements
    ADD CONSTRAINT user_seen_announcements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_sessions user_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: video_integrations video_integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_integrations
    ADD CONSTRAINT video_integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: webhook_deliveries webhook_deliveries_webhook_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_webhook_id_fkey FOREIGN KEY (webhook_id) REFERENCES public.webhooks(id) ON DELETE CASCADE;


--
-- Name: webhooks webhooks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhooks
    ADD CONSTRAINT webhooks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: weekly_availability weekly_availability_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_availability
    ADD CONSTRAINT weekly_availability_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict fgOvFznF3h80d0g7kMBCd73tBexwbZF1R5JpvptfvFUYwogjcfumxeGqdnm8oq2

INSERT INTO public."schema_migrations" (version) VALUES (20250701180112);
INSERT INTO public."schema_migrations" (version) VALUES (20250701180204);
INSERT INTO public."schema_migrations" (version) VALUES (20250701192042);
INSERT INTO public."schema_migrations" (version) VALUES (20250702153644);
INSERT INTO public."schema_migrations" (version) VALUES (20250702154152);
INSERT INTO public."schema_migrations" (version) VALUES (20250702181205);
INSERT INTO public."schema_migrations" (version) VALUES (20250704153243);
INSERT INTO public."schema_migrations" (version) VALUES (20250705083251);
INSERT INTO public."schema_migrations" (version) VALUES (20250710115904);
INSERT INTO public."schema_migrations" (version) VALUES (20250710120005);
INSERT INTO public."schema_migrations" (version) VALUES (20250714080356);
INSERT INTO public."schema_migrations" (version) VALUES (20250714084624);
INSERT INTO public."schema_migrations" (version) VALUES (20250714084717);
INSERT INTO public."schema_migrations" (version) VALUES (20250714124038);
INSERT INTO public."schema_migrations" (version) VALUES (20250714131818);
INSERT INTO public."schema_migrations" (version) VALUES (20250714131852);
INSERT INTO public."schema_migrations" (version) VALUES (20250714135507);
INSERT INTO public."schema_migrations" (version) VALUES (20250715091916);
INSERT INTO public."schema_migrations" (version) VALUES (20250716062620);
INSERT INTO public."schema_migrations" (version) VALUES (20250716075224);
INSERT INTO public."schema_migrations" (version) VALUES (20250716084830);
INSERT INTO public."schema_migrations" (version) VALUES (20250716105819);
INSERT INTO public."schema_migrations" (version) VALUES (20250717122641);
INSERT INTO public."schema_migrations" (version) VALUES (20250717150920);
INSERT INTO public."schema_migrations" (version) VALUES (20250718140725);
INSERT INTO public."schema_migrations" (version) VALUES (20250718162438);
INSERT INTO public."schema_migrations" (version) VALUES (20250719081220);
INSERT INTO public."schema_migrations" (version) VALUES (20250719081421);
INSERT INTO public."schema_migrations" (version) VALUES (20250719111923);
INSERT INTO public."schema_migrations" (version) VALUES (20250721152458);
INSERT INTO public."schema_migrations" (version) VALUES (20250721152603);
INSERT INTO public."schema_migrations" (version) VALUES (20250721152654);
INSERT INTO public."schema_migrations" (version) VALUES (20250721153548);
INSERT INTO public."schema_migrations" (version) VALUES (20250722074740);
INSERT INTO public."schema_migrations" (version) VALUES (20250722074913);
INSERT INTO public."schema_migrations" (version) VALUES (20250722151625);
INSERT INTO public."schema_migrations" (version) VALUES (20250723103856);
INSERT INTO public."schema_migrations" (version) VALUES (20250723165833);
INSERT INTO public."schema_migrations" (version) VALUES (20250724174838);
INSERT INTO public."schema_migrations" (version) VALUES (20250724175724);
INSERT INTO public."schema_migrations" (version) VALUES (20250726084948);
INSERT INTO public."schema_migrations" (version) VALUES (20250726085500);
INSERT INTO public."schema_migrations" (version) VALUES (20250726120000);
INSERT INTO public."schema_migrations" (version) VALUES (20250728144626);
INSERT INTO public."schema_migrations" (version) VALUES (20250728161037);
INSERT INTO public."schema_migrations" (version) VALUES (20250730080200);
INSERT INTO public."schema_migrations" (version) VALUES (20250801070834);
INSERT INTO public."schema_migrations" (version) VALUES (20250804135627);
INSERT INTO public."schema_migrations" (version) VALUES (20250816081351);
INSERT INTO public."schema_migrations" (version) VALUES (20250818133052);
INSERT INTO public."schema_migrations" (version) VALUES (20250912151110);
INSERT INTO public."schema_migrations" (version) VALUES (20250912151120);
INSERT INTO public."schema_migrations" (version) VALUES (20250914085000);
INSERT INTO public."schema_migrations" (version) VALUES (20250918122600);
INSERT INTO public."schema_migrations" (version) VALUES (20250918122700);
INSERT INTO public."schema_migrations" (version) VALUES (20250918123500);
INSERT INTO public."schema_migrations" (version) VALUES (20251002144519);
INSERT INTO public."schema_migrations" (version) VALUES (20251004115230);
INSERT INTO public."schema_migrations" (version) VALUES (20251004115240);
INSERT INTO public."schema_migrations" (version) VALUES (20251004115250);
INSERT INTO public."schema_migrations" (version) VALUES (20251117091200);
INSERT INTO public."schema_migrations" (version) VALUES (20251214000000);
INSERT INTO public."schema_migrations" (version) VALUES (20251221000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260106132718);
INSERT INTO public."schema_migrations" (version) VALUES (20260107173504);
INSERT INTO public."schema_migrations" (version) VALUES (20260107173505);
INSERT INTO public."schema_migrations" (version) VALUES (20260108092516);
INSERT INTO public."schema_migrations" (version) VALUES (20260108095059);
INSERT INTO public."schema_migrations" (version) VALUES (20260108110833);
INSERT INTO public."schema_migrations" (version) VALUES (20260115120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260115143000);
INSERT INTO public."schema_migrations" (version) VALUES (20260115150000);
INSERT INTO public."schema_migrations" (version) VALUES (20260116140703);
INSERT INTO public."schema_migrations" (version) VALUES (20260116150000);
INSERT INTO public."schema_migrations" (version) VALUES (20260116153000);
INSERT INTO public."schema_migrations" (version) VALUES (20260116160414);
INSERT INTO public."schema_migrations" (version) VALUES (20260118120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260126182236);
INSERT INTO public."schema_migrations" (version) VALUES (20260126182239);
INSERT INTO public."schema_migrations" (version) VALUES (20260129121212);
INSERT INTO public."schema_migrations" (version) VALUES (20260129164500);
INSERT INTO public."schema_migrations" (version) VALUES (20260209000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260212000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260220000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260224000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260224143101);
INSERT INTO public."schema_migrations" (version) VALUES (20260226120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260226160000);
INSERT INTO public."schema_migrations" (version) VALUES (20260227000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260305000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260305000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260306000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260317000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260317000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260317000003);
INSERT INTO public."schema_migrations" (version) VALUES (20260319000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260323000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260329000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260401000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000003);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000004);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000005);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000006);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000007);
INSERT INTO public."schema_migrations" (version) VALUES (20260402000008);
INSERT INTO public."schema_migrations" (version) VALUES (20260406095819);
INSERT INTO public."schema_migrations" (version) VALUES (20260408110831);
INSERT INTO public."schema_migrations" (version) VALUES (20260413112551);
INSERT INTO public."schema_migrations" (version) VALUES (20260415154744);
INSERT INTO public."schema_migrations" (version) VALUES (20260415181838);
INSERT INTO public."schema_migrations" (version) VALUES (20260415184637);
INSERT INTO public."schema_migrations" (version) VALUES (20260415185057);
INSERT INTO public."schema_migrations" (version) VALUES (20260415192059);
INSERT INTO public."schema_migrations" (version) VALUES (20260415200114);
INSERT INTO public."schema_migrations" (version) VALUES (20260417062658);
INSERT INTO public."schema_migrations" (version) VALUES (20260420143229);
INSERT INTO public."schema_migrations" (version) VALUES (20260420161816);
INSERT INTO public."schema_migrations" (version) VALUES (20260427152341);
INSERT INTO public."schema_migrations" (version) VALUES (20260506133159);
INSERT INTO public."schema_migrations" (version) VALUES (20260507064500);
INSERT INTO public."schema_migrations" (version) VALUES (20260508072935);
INSERT INTO public."schema_migrations" (version) VALUES (20260508090605);
INSERT INTO public."schema_migrations" (version) VALUES (20260513100000);
INSERT INTO public."schema_migrations" (version) VALUES (20260513104937);
INSERT INTO public."schema_migrations" (version) VALUES (20260513120815);
INSERT INTO public."schema_migrations" (version) VALUES (20260513121703);
INSERT INTO public."schema_migrations" (version) VALUES (20260513122000);
INSERT INTO public."schema_migrations" (version) VALUES (20260513131755);
INSERT INTO public."schema_migrations" (version) VALUES (20260513131758);
INSERT INTO public."schema_migrations" (version) VALUES (20260516123251);
INSERT INTO public."schema_migrations" (version) VALUES (20260516141548);
INSERT INTO public."schema_migrations" (version) VALUES (20260519102624);
INSERT INTO public."schema_migrations" (version) VALUES (20260527165324);
INSERT INTO public."schema_migrations" (version) VALUES (20260527173402);
