-- Seed Data for Testing
-- Note: Replace with actual Firebase UIDs when testing in dev

INSERT INTO virtual_accounts (user_id, balance, role, status) 
VALUES 
('system-reserve', 0.00, 'system', 'active'),
('mock-student-1', 1000.00, 'student', 'active'),
('mock-merchant-1', 0.00, 'merchant', 'active');
