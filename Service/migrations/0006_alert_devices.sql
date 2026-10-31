-- Which devices take the service's event alerts: the ones that have reported the alerts they hold
-- (build 60 on). A device from before never gets one, so its own alerts never come twice.
ALTER TABLE devices ADD COLUMN alerts_at BIGINT;
