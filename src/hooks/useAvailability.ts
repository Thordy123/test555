import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';

export interface AvailabilitySlot {
  id: string;
  spot_id: string;
  date: string;
  start_time: string;
  end_time: string;
  available_slots: number;
  status: 'available' | 'blocked' | 'maintenance';
  reason?: string;
}

export const useAvailability = (spotId?: string) => {
  const [availability, setAvailability] = useState<AvailabilitySlot[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchAvailability = async () => {
    if (!spotId) return;

    try {
      const { data, error } = await supabase
        .from('parking_spot_availability')
        .select('*')
        .eq('spot_id', spotId)
        .gte('date', new Date().toISOString().split('T')[0])
        .order('date', { ascending: true })
        .order('start_time', { ascending: true });

      if (error) throw error;

      setAvailability(data || []);
    } catch (error) {
      console.error('Error fetching availability:', error);
    } finally {
      setLoading(false);
    }
  };

  const checkAvailability = async (
    spotId: string,
    date: string,
    startTime: string,
    endTime: string
  ): Promise<number> => {
    try {
      const { data, error } = await supabase.rpc('get_spot_availability', {
        p_spot_id: spotId,
        p_date: date,
        p_start_time: startTime,
        p_end_time: endTime,
      });

      if (error) throw error;

      return data || 0;
    } catch (error) {
      console.error('Error checking availability:', error);
      return 0;
    }
  };

  const createAvailabilityBlock = async (block: Omit<AvailabilitySlot, 'id'>) => {
    try {
      const { data, error } = await supabase
        .from('parking_spot_availability')
        .insert(block)
        .select()
        .single();

      if (error) throw error;

      setAvailability(prev => [...prev, data]);
      return data;
    } catch (error) {
      console.error('Error creating availability block:', error);
      throw error;
    }
  };

  const updateAvailabilityBlock = async (
    id: string,
    updates: Partial<AvailabilitySlot>
  ) => {
    try {
      const { data, error } = await supabase
        .from('parking_spot_availability')
        .update(updates)
        .eq('id', id)
        .select()
        .single();

      if (error) throw error;

      setAvailability(prev =>
        prev.map(slot => (slot.id === id ? data : slot))
      );
      return data;
    } catch (error) {
      console.error('Error updating availability block:', error);
      throw error;
    }
  };

  const deleteAvailabilityBlock = async (id: string) => {
    try {
      const { error } = await supabase
        .from('parking_spot_availability')
        .delete()
        .eq('id', id);

      if (error) throw error;

      setAvailability(prev => prev.filter(slot => slot.id !== id));
    } catch (error) {
      console.error('Error deleting availability block:', error);
      throw error;
    }
  };

  useEffect(() => {
    if (spotId) {
      fetchAvailability();
    }
  }, [spotId]);

  return {
    availability,
    loading,
    checkAvailability,
    createAvailabilityBlock,
    updateAvailabilityBlock,
    deleteAvailabilityBlock,
    refetch: fetchAvailability,
  };
};