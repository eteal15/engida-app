-- ENGIDA (እንግዳ) - Database Schema Migration
-- Target: Supabase (PostgreSQL)
-- Run this in Supabase Dashboard > SQL Editor

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. ENUMS & TYPES
CREATE TYPE user_role AS ENUM ('Reader', 'Writer', 'Admin');
CREATE TYPE story_status AS ENUM ('draft', 'pending', 'approved', 'rejected');
CREATE TYPE interaction_type AS ENUM ('like', 'bookmark', 'reading_history');
CREATE TYPE transaction_type AS ENUM ('deposit', 'purchase', 'payout');

-- 3. TABLES

-- Profiles (Linked to Supabase Auth - UUID matches auth.users.id)
CREATE TABLE public.profiles (
    id UUID REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
    username TEXT UNIQUE,
    full_name TEXT,
    avatar_url TEXT,
    bio TEXT,
    role user_role DEFAULT 'Reader' NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Stories
CREATE TABLE public.stories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    cover_url TEXT,
    genre TEXT,
    status story_status DEFAULT 'draft' NOT NULL,
    views_count BIGINT DEFAULT 0,
    likes_count BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Chapters
CREATE TABLE public.chapters (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    story_id UUID REFERENCES public.stories(id) ON DELETE CASCADE NOT NULL,
    chapter_number INT NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    is_locked BOOLEAN DEFAULT FALSE,
    coin_price INT DEFAULT 5,
    views_count BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(story_id, chapter_number)
);

-- Coin Wallets
CREATE TABLE public.coin_wallets (
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE PRIMARY KEY,
    balance INT DEFAULT 0 CHECK (balance >= 0) NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Transactions (Telebirr Records / Chapter Purchases)
CREATE TABLE public.transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.profiles(id) NOT NULL,
    type transaction_type NOT NULL,
    amount INT NOT NULL,
    reference_id TEXT UNIQUE,
    screenshot_url TEXT,
    status TEXT DEFAULT 'pending' NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Chapter Unlocks (Permanent ledger of purchased chapters)
CREATE TABLE public.chapter_unlocks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    chapter_id UUID REFERENCES public.chapters(id) ON DELETE CASCADE NOT NULL,
    unlocked_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, chapter_id)
);

-- User Interactions (likes, bookmarks, reading history)
CREATE TABLE public.user_interactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    story_id UUID REFERENCES public.stories(id) ON DELETE CASCADE NOT NULL,
    chapter_id UUID REFERENCES public.chapters(id) ON DELETE CASCADE,
    type interaction_type NOT NULL,
    last_position INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, story_id, type)
);

-- Monetization Requests
CREATE TABLE public.monetization_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    writer_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    status TEXT DEFAULT 'pending' NOT NULL,
    full_name TEXT,
    phone TEXT,
    email TEXT,
    telebirr_number TEXT,
    total_stories_completed INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Payout Records
CREATE TABLE public.payout_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    writer_id UUID REFERENCES public.profiles(id) NOT NULL,
    amount_etb DECIMAL(10,2) NOT NULL,
    status TEXT DEFAULT 'processing' NOT NULL,
    transfer_reference TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. PERFORMANCE INDEXES
CREATE INDEX idx_stories_status ON public.stories(status);
CREATE INDEX idx_stories_genre ON public.stories(genre);
CREATE INDEX idx_chapters_story_id ON public.chapters(story_id);
CREATE INDEX idx_interactions_user_history ON public.user_interactions(user_id, type);
CREATE INDEX idx_transactions_user ON public.transactions(user_id);

-- 5. ROW-LEVEL SECURITY (RLS)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coin_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chapter_unlocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monetization_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payout_records ENABLE ROW LEVEL SECURITY;

-- Profiles: Anyone can read, only owner can update
CREATE POLICY "Public profiles are viewable by everyone" ON public.profiles
    FOR SELECT USING (true);
CREATE POLICY "Users can insert own profile" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- Stories: Approved = public. Authors manage own. Admins manage all.
CREATE POLICY "Approved stories are public" ON public.stories
    FOR SELECT USING (status = 'approved');
CREATE POLICY "Authors can manage their stories" ON public.stories
    FOR ALL USING (auth.uid() = author_id);
CREATE POLICY "Admins can manage all stories" ON public.stories
    FOR ALL TO authenticated USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin')
    );

-- Chapters
CREATE POLICY "Free chapters are public" ON public.chapters
    FOR SELECT USING (
        is_locked = false AND 
        EXISTS (SELECT 1 FROM public.stories WHERE id = chapters.story_id AND status = 'approved')
    );
CREATE POLICY "Unlocked chapters are viewable by owner" ON public.chapters
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.chapter_unlocks WHERE user_id = auth.uid() AND chapter_id = chapters.id)
    );
CREATE POLICY "Authors can manage their chapters" ON public.chapters
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.stories WHERE id = chapters.story_id AND author_id = auth.uid())
    );
CREATE POLICY "Admins can manage all chapters" ON public.chapters
    FOR ALL TO authenticated USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin')
    );

-- Wallets
CREATE POLICY "Users can see own wallet" ON public.coin_wallets
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "System can insert wallets" ON public.coin_wallets
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Transactions
CREATE POLICY "Users can see own transactions" ON public.transactions
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own transactions" ON public.transactions
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Admins can manage all transactions" ON public.transactions
    FOR ALL TO authenticated USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin')
    );

-- Chapter Unlocks
CREATE POLICY "Users can see own unlocks" ON public.chapter_unlocks
    FOR SELECT USING (auth.uid() = user_id);

-- User Interactions
CREATE POLICY "Users can manage own interactions" ON public.user_interactions
    FOR ALL USING (auth.uid() = user_id);

-- Monetization
CREATE POLICY "Writers can manage own requests" ON public.monetization_requests
    FOR ALL USING (auth.uid() = writer_id);
CREATE POLICY "Admins can manage all monetization" ON public.monetization_requests
    FOR ALL TO authenticated USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin')
    );

-- Payouts
CREATE POLICY "Writers can see own payouts" ON public.payout_records
    FOR SELECT USING (auth.uid() = writer_id);
CREATE POLICY "Admins can manage all payouts" ON public.payout_records
    FOR ALL TO authenticated USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin')
    );

-- 6. TRIGGERS & FUNCTIONS

-- Auto-create profile and wallet after Google/email signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    -- Create profile from OAuth metadata (Google provides name and picture)
    INSERT INTO public.profiles (id, full_name, avatar_url, username, role)
    VALUES (
        new.id,
        COALESCE(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
        new.raw_user_meta_data->>'avatar_url',
        split_part(new.email, '@', 1),
        'Reader'
    )
    ON CONFLICT (id) DO NOTHING;
    
    -- Create coin wallet with 0 balance
    INSERT INTO public.coin_wallets (user_id, balance)
    VALUES (new.id, 0)
    ON CONFLICT (user_id) DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Atomic Chapter Purchase (called via supabase.rpc)
CREATE OR REPLACE FUNCTION public.unlock_chapter(target_chapter_id UUID)
RETURNS VOID AS $$
DECLARE
    chapter_price INT;
    user_balance INT;
    already_unlocked BOOLEAN;
BEGIN
    -- Check if already unlocked
    SELECT EXISTS(
        SELECT 1 FROM public.chapter_unlocks 
        WHERE user_id = auth.uid() AND chapter_id = target_chapter_id
    ) INTO already_unlocked;
    
    IF already_unlocked THEN
        RETURN; -- Already unlocked, no charge
    END IF;

    -- Get chapter price
    SELECT coin_price INTO chapter_price FROM public.chapters WHERE id = target_chapter_id;
    
    IF chapter_price IS NULL THEN
        RAISE EXCEPTION 'Chapter not found';
    END IF;

    -- Get user balance
    SELECT balance INTO user_balance FROM public.coin_wallets WHERE user_id = auth.uid();

    IF user_balance IS NULL OR user_balance < chapter_price THEN
        RAISE EXCEPTION 'Insufficient balance';
    END IF;

    -- Deduct balance atomically
    UPDATE public.coin_wallets
    SET balance = balance - chapter_price, updated_at = NOW()
    WHERE user_id = auth.uid();

    -- Record transaction
    INSERT INTO public.transactions (user_id, type, amount, status, metadata)
    VALUES (auth.uid(), 'purchase', -chapter_price, 'completed', jsonb_build_object('chapter_id', target_chapter_id));

    -- Add to unlocks ledger
    INSERT INTO public.chapter_unlocks (user_id, chapter_id)
    VALUES (auth.uid(), target_chapter_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Admin function to approve a Telebirr payment and add coins
CREATE OR REPLACE FUNCTION public.approve_payment(transaction_id UUID, coins_to_add INT)
RETURNS VOID AS $$
DECLARE
    target_user_id UUID;
BEGIN
    -- Only admins can call this
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'Admin') THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    SELECT user_id INTO target_user_id FROM public.transactions WHERE id = transaction_id;

    -- Update transaction status
    UPDATE public.transactions SET status = 'completed' WHERE id = transaction_id;

    -- Add coins to user wallet
    UPDATE public.coin_wallets 
    SET balance = balance + coins_to_add, updated_at = NOW()
    WHERE user_id = target_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ADDITIONAL: Ensure wallet is created if user signs up via email
-- (the trigger already handles this, but add an upsert safety net)
CREATE OR REPLACE FUNCTION public.ensure_wallet_exists(target_user_id UUID)
RETURNS VOID AS $$
BEGIN
  INSERT INTO public.coin_wallets (user_id, balance)
  VALUES (target_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Allow authenticated users to insert their own profile (for signup flow)
CREATE POLICY "Users can insert own profile" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Allow wallets to be created via trigger
CREATE POLICY "System can create wallets" ON public.coin_wallets
    FOR INSERT WITH CHECK (auth.uid() = user_id);
