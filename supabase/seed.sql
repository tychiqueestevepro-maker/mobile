-- Deterministic San Francisco demo catalogue. Provider and infrastructure names
-- are deliberately absent from consumer-facing content.
insert into public.retailers(id, name, service_fee_bps, delivery_fee_cents, free_delivery_threshold_cents) values
  ('market-street', 'Market Street Market', 500, 699, 5000),
  ('mission-goods', 'Mission Goods', 350, 599, 4500),
  ('bay-essentials', 'Bay Essentials', 250, 799, 6000)
on conflict (id) do update set
  name = excluded.name,
  service_fee_bps = excluded.service_fee_bps,
  delivery_fee_cents = excluded.delivery_fee_cents,
  free_delivery_threshold_cents = excluded.free_delivery_threshold_cents,
  active = true;

insert into public.products(
  id, category, name, brand, description, format, size_value, size_unit,
  unit_count, attributes, keywords
) values
  ('trash-heavy-30', 'trash_bags', 'Heavy-Duty Drawstring Trash Bags', 'HeavyHold',
   'Tear-resistant kitchen bags with drawstring closure.', 'drawstring', 13, 'gal', 30,
   '{"color":"black","strength":"heavy-duty","scent":"unscented","material":"plastic"}',
   array['trash bags','garbage bags','kitchen bags','bin liners']),
  ('trash-value-45', 'trash_bags', 'Everyday Kitchen Trash Bags', 'DailyBasics',
   'Reliable kitchen bags in a larger value pack.', 'drawstring', 13, 'gal', 45,
   '{"color":"white","strength":"standard","scent":"unscented","material":"plastic"}',
   array['trash bags','garbage bags','kitchen bags','value']),
  ('trash-eco-25', 'trash_bags', 'Recycled Kitchen Trash Bags', 'GreenNest',
   'Kitchen bags made with post-consumer recycled material.', 'drawstring', 13, 'gal', 25,
   '{"color":"green","strength":"standard","scent":"unscented","material":"recycled"}',
   array['trash bags','eco','recycled','bin liners']),
  ('trash-small-40', 'trash_bags', 'Small Bin Liners', 'DailyBasics',
   'Compact liners for bathroom and office bins.', 'tie', 4, 'gal', 40,
   '{"color":"white","strength":"standard","scent":"fresh","material":"plastic"}',
   array['small trash bags','bathroom bags','office bin liners']),

  ('toothpaste-sensitive', 'toothpaste', 'Sensitive Care Toothpaste', 'GentleMint',
   'Mild mint toothpaste formulated for sensitive teeth.', 'paste', 4, 'oz', 1,
   '{"flavor":"mild mint","sensitivity":"yes","fluoride":"yes","whitening":"no"}',
   array['toothpaste','sensitive teeth','fluoride','mild mint']),
  ('toothpaste-whitening', 'toothpaste', 'Whitening Mint Toothpaste', 'BrightDay',
   'Fresh mint fluoride toothpaste with whitening care.', 'paste', 5.2, 'oz', 1,
   '{"flavor":"fresh mint","sensitivity":"no","fluoride":"yes","whitening":"yes"}',
   array['toothpaste','whitening','fluoride','mint']),
  ('toothpaste-tablets', 'toothpaste', 'Mint Toothpaste Tablets', 'GreenNest',
   'Low-waste chewable toothpaste tablets in a refillable tin.', 'tablets', 62, 'count', 1,
   '{"flavor":"mint","sensitivity":"no","fluoride":"yes","packaging":"refillable"}',
   array['toothpaste','tablets','low waste','travel']),
  ('toothpaste-value-2', 'toothpaste', 'Everyday Mint Toothpaste Twin Pack', 'DailyBasics',
   'A two-pack of everyday fluoride toothpaste.', 'paste', 6, 'oz', 2,
   '{"flavor":"mint","sensitivity":"no","fluoride":"yes","whitening":"no"}',
   array['toothpaste','value','two pack','fluoride']),

  ('paper-soft-6', 'paper_towels', 'Soft & Strong Paper Towels', 'CloudHome',
   'Absorbent two-ply paper towels.', 'roll', 110, 'sheet', 6,
   '{"ply":"2","select-a-size":"yes","material":"paper"}',
   array['paper towels','kitchen paper','absorbent']),
  ('paper-recycled-6', 'paper_towels', '100% Recycled Paper Towels', 'GreenNest',
   'Unbleached paper towels made from recycled fibers.', 'roll', 100, 'sheet', 6,
   '{"ply":"2","select-a-size":"yes","material":"recycled"}',
   array['paper towels','recycled','eco']),

  ('dish-free-clear', 'dish_soap', 'Free & Clear Dish Soap', 'GentleHome',
   'Fragrance-free concentrated dish liquid.', 'liquid', 24, 'fl oz', 1,
   '{"scent":"fragrance-free","concentrated":"yes","dye-free":"yes"}',
   array['dish soap','fragrance free','washing up liquid']),
  ('dish-citrus', 'dish_soap', 'Citrus Dish Soap', 'BrightDay',
   'Grease-cutting dish liquid with a fresh citrus scent.', 'liquid', 28, 'fl oz', 1,
   '{"scent":"citrus","concentrated":"yes","dye-free":"no"}',
   array['dish soap','citrus','grease']),

  ('laundry-sensitive', 'laundry_detergent', 'Sensitive Laundry Detergent', 'GentleHome',
   'Unscented detergent for sensitive skin.', 'liquid', 64, 'fl oz', 64,
   '{"scent":"unscented","sensitive":"yes","he":"yes"}',
   array['laundry detergent','sensitive skin','unscented']),
  ('laundry-pods', 'laundry_detergent', 'Fresh Laundry Pods', 'BrightDay',
   'Pre-measured laundry detergent pods.', 'pods', 42, 'count', 42,
   '{"scent":"fresh","sensitive":"no","he":"yes"}',
   array['laundry detergent','pods','fresh']),

  ('hand-soap-refill', 'hand_soap', 'Unscented Hand Soap Refill', 'GentleHome',
   'Fragrance-free moisturizing hand soap refill.', 'liquid refill', 34, 'fl oz', 1,
   '{"scent":"unscented","refill":"yes","dye-free":"yes"}',
   array['hand soap','refill','fragrance free'])
on conflict (id) do update set
  category = excluded.category, name = excluded.name, brand = excluded.brand,
  description = excluded.description, format = excluded.format,
  size_value = excluded.size_value, size_unit = excluded.size_unit,
  unit_count = excluded.unit_count, attributes = excluded.attributes,
  keywords = excluded.keywords, active = true;

insert into public.product_offers(
  product_id, retailer_id, external_offer_id, price_cents, currency, available, inventory_count
) values
  ('trash-heavy-30', 'market-street', 'ms-trash-heavy-30', 1299, 'USD', true, 18),
  ('trash-heavy-30', 'mission-goods', 'mg-trash-heavy-30', 1249, 'USD', true, 10),
  ('trash-value-45', 'market-street', 'ms-trash-value-45', 1399, 'USD', true, 22),
  ('trash-value-45', 'bay-essentials', 'be-trash-value-45', 1199, 'USD', true, 14),
  ('trash-eco-25', 'mission-goods', 'mg-trash-eco-25', 1349, 'USD', true, 9),
  ('trash-eco-25', 'bay-essentials', 'be-trash-eco-25', 1299, 'USD', true, 8),
  ('trash-small-40', 'market-street', 'ms-trash-small-40', 749, 'USD', true, 16),

  ('toothpaste-sensitive', 'market-street', 'ms-tooth-sensitive', 699, 'USD', true, 25),
  ('toothpaste-sensitive', 'mission-goods', 'mg-tooth-sensitive', 649, 'USD', true, 19),
  ('toothpaste-whitening', 'market-street', 'ms-tooth-whitening', 599, 'USD', true, 30),
  ('toothpaste-whitening', 'bay-essentials', 'be-tooth-whitening', 549, 'USD', true, 27),
  ('toothpaste-tablets', 'mission-goods', 'mg-tooth-tablets', 999, 'USD', true, 12),
  ('toothpaste-tablets', 'bay-essentials', 'be-tooth-tablets', 949, 'USD', true, 11),
  ('toothpaste-value-2', 'market-street', 'ms-tooth-value-2', 849, 'USD', true, 24),

  ('paper-soft-6', 'market-street', 'ms-paper-soft-6', 1199, 'USD', true, 15),
  ('paper-soft-6', 'bay-essentials', 'be-paper-soft-6', 1099, 'USD', true, 12),
  ('paper-recycled-6', 'mission-goods', 'mg-paper-recycled-6', 1299, 'USD', true, 10),
  ('dish-free-clear', 'mission-goods', 'mg-dish-free-clear', 699, 'USD', true, 20),
  ('dish-free-clear', 'bay-essentials', 'be-dish-free-clear', 649, 'USD', true, 18),
  ('dish-citrus', 'market-street', 'ms-dish-citrus', 549, 'USD', true, 35),
  ('laundry-sensitive', 'mission-goods', 'mg-laundry-sensitive', 1599, 'USD', true, 13),
  ('laundry-sensitive', 'bay-essentials', 'be-laundry-sensitive', 1549, 'USD', true, 9),
  ('laundry-pods', 'market-street', 'ms-laundry-pods', 1499, 'USD', true, 20),
  ('hand-soap-refill', 'mission-goods', 'mg-hand-soap-refill', 899, 'USD', true, 14)
on conflict (product_id, retailer_id) do update set
  external_offer_id = excluded.external_offer_id,
  price_cents = excluded.price_cents,
  currency = excluded.currency,
  available = excluded.available,
  inventory_count = excluded.inventory_count,
  updated_at = now();
