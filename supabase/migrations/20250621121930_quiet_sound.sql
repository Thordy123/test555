/*
  # Enhanced Features for Parking Booking System

  1. New Tables
    - `parking_spot_availability` - Granular availability management
    - `booking_extensions` - Track time extensions
    - `notifications` - User notification system
    - `favorites` - User favorite parking spots
    - `pricing_rules` - Dynamic pricing based on time/demand

  2. Enhanced Features
    - Real-time availability tracking
    - Dynamic pricing support
    - Notification system
    - Favorites functionality
    - Better audit trail

  3. Indexes
    - Performance optimization for common queries
*/

-- Parking spot availability management
CREATE TABLE IF NOT EXISTS parking_spot_availability (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  spot_id uuid REFERENCES parking_spots(id) ON DELETE CASCADE,
  date date NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  available_slots integer NOT NULL DEFAULT 0,
  status text CHECK (status IN ('available', 'blocked', 'maintenance')) DEFAULT 'available',
  reason text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(spot_id, date, start_time, end_time)
);

-- Booking extensions tracking
CREATE TABLE IF NOT EXISTS booking_extensions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid REFERENCES bookings(id) ON DELETE CASCADE,
  original_end_time timestamptz NOT NULL,
  new_end_time timestamptz NOT NULL,
  extension_cost decimal(10,2) NOT NULL,
  status text CHECK (status IN ('pending', 'approved', 'rejected')) DEFAULT 'pending',
  requested_at timestamptz DEFAULT now(),
  processed_at timestamptz,
  processed_by uuid REFERENCES profiles(id)
);

-- User notifications
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  title text NOT NULL,
  message text NOT NULL,
  type text CHECK (type IN ('booking', 'payment', 'review', 'system', 'extension')) NOT NULL,
  is_read boolean DEFAULT false,
  action_url text,
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz
);

-- User favorites
CREATE TABLE IF NOT EXISTS user_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  spot_id uuid REFERENCES parking_spots(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, spot_id)
);

-- Dynamic pricing rules
CREATE TABLE IF NOT EXISTS pricing_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  spot_id uuid REFERENCES parking_spots(id) ON DELETE CASCADE,
  rule_name text NOT NULL,
  day_of_week integer[], -- 0=Sunday, 1=Monday, etc.
  start_time time,
  end_time time,
  date_from date,
  date_to date,
  price_multiplier decimal(3,2) DEFAULT 1.0,
  fixed_price decimal(10,2),
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Booking audit trail
CREATE TABLE IF NOT EXISTS booking_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid REFERENCES bookings(id) ON DELETE CASCADE,
  action text NOT NULL, -- 'created', 'confirmed', 'cancelled', 'extended', etc.
  old_values jsonb,
  new_values jsonb,
  performed_by uuid REFERENCES profiles(id),
  performed_at timestamptz DEFAULT now(),
  notes text
);

-- Enable RLS on all new tables
ALTER TABLE parking_spot_availability ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_extensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_audit ENABLE ROW LEVEL SECURITY;

-- RLS Policies for parking_spot_availability
CREATE POLICY "Users can view availability for any spot"
  ON parking_spot_availability
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Owners can manage their spot availability"
  ON parking_spot_availability
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM parking_spots 
      WHERE id = spot_id AND owner_id = auth.uid()
    )
  );

-- RLS Policies for booking_extensions
CREATE POLICY "Users can view their booking extensions"
  ON booking_extensions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM bookings 
      WHERE id = booking_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "Users can create extensions for their bookings"
  ON booking_extensions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM bookings 
      WHERE id = booking_id AND user_id = auth.uid()
    )
  );

-- RLS Policies for notifications
CREATE POLICY "Users can view their notifications"
  ON notifications
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Users can update their notifications"
  ON notifications
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid());

-- RLS Policies for user_favorites
CREATE POLICY "Users can manage their favorites"
  ON user_favorites
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid());

-- RLS Policies for pricing_rules
CREATE POLICY "Users can view pricing rules"
  ON pricing_rules
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Owners can manage their pricing rules"
  ON pricing_rules
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM parking_spots 
      WHERE id = spot_id AND owner_id = auth.uid()
    )
  );

-- RLS Policies for booking_audit
CREATE POLICY "Users can view audit for their bookings"
  ON booking_audit
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM bookings 
      WHERE id = booking_id AND (user_id = auth.uid() OR 
        EXISTS (SELECT 1 FROM parking_spots WHERE id = bookings.spot_id AND owner_id = auth.uid()))
    )
  );

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_parking_spot_availability_spot_date 
  ON parking_spot_availability(spot_id, date);

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread 
  ON notifications(user_id, is_read, created_at);

CREATE INDEX IF NOT EXISTS idx_user_favorites_user 
  ON user_favorites(user_id);

CREATE INDEX IF NOT EXISTS idx_pricing_rules_spot_active 
  ON pricing_rules(spot_id, is_active);

CREATE INDEX IF NOT EXISTS idx_booking_audit_booking 
  ON booking_audit(booking_id, performed_at);

-- Add updated_at trigger for tables that need it
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_parking_spot_availability_updated_at 
  BEFORE UPDATE ON parking_spot_availability 
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pricing_rules_updated_at 
  BEFORE UPDATE ON pricing_rules 
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Add some useful functions
CREATE OR REPLACE FUNCTION get_spot_availability(
  p_spot_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time
)
RETURNS integer AS $$
DECLARE
  available_slots integer := 0;
  total_slots integer;
BEGIN
  -- Get total slots for the spot
  SELECT ps.total_slots INTO total_slots
  FROM parking_spots ps
  WHERE ps.id = p_spot_id;
  
  -- Check if there's a specific availability record
  SELECT COALESCE(psa.available_slots, total_slots) INTO available_slots
  FROM parking_spot_availability psa
  WHERE psa.spot_id = p_spot_id
    AND psa.date = p_date
    AND psa.start_time <= p_start_time
    AND psa.end_time >= p_end_time
    AND psa.status = 'available'
  ORDER BY psa.created_at DESC
  LIMIT 1;
  
  -- If no specific record, use total slots
  IF available_slots IS NULL THEN
    available_slots := total_slots;
  END IF;
  
  -- Subtract booked slots
  SELECT available_slots - COALESCE(COUNT(*), 0) INTO available_slots
  FROM bookings b
  WHERE b.spot_id = p_spot_id
    AND b.status IN ('confirmed', 'active')
    AND DATE(b.start_time) = p_date
    AND TIME(b.start_time) < p_end_time
    AND TIME(b.end_time) > p_start_time;
  
  RETURN GREATEST(available_slots, 0);
END;
$$ LANGUAGE plpgsql;

-- Function to create notification
CREATE OR REPLACE FUNCTION create_notification(
  p_user_id uuid,
  p_title text,
  p_message text,
  p_type text,
  p_action_url text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'
)
RETURNS uuid AS $$
DECLARE
  notification_id uuid;
BEGIN
  INSERT INTO notifications (user_id, title, message, type, action_url, metadata)
  VALUES (p_user_id, p_title, p_message, p_type, p_action_url, p_metadata)
  RETURNING id INTO notification_id;
  
  RETURN notification_id;
END;
$$ LANGUAGE plpgsql;