{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}

import           Control.Lens        (Getting, Sequenced, allOf, filtered,
                                      forMOf_, makeLenses, modifying, toListOf,
                                      views)
import           Control.Monad       (forM, join, when)
import           Control.Monad.Loops (untilM)
import           Control.Monad.State (MonadState, State, get, gets, runState)
import           Data.Function       (on)
import           Data.List           (find, genericLength, notElem, sort,
                                      sortOn)
import qualified Data.List.Safe      as L
import qualified Data.Map.Strict     as M
import           Data.Maybe          (fromMaybe, mapMaybe)
import           Data.Tuple          (swap)

-- LOAD INPUT
loadInput :: IO String
loadInput = readFile "inputs/day-15.txt"

-- TYPES AND RELATED FUNCTIONS
-- ELEMENTAL TYPES
newtype Size =
    Size (Integer, Integer)
    deriving (Eq, Show)

newtype Position =
    Position (Integer, Integer)
    deriving (Eq, Show)

instance Ord Position where
    Position (x0, y0) <= Position (x1, y1) =
        if y0 /= y1
            then y0 <= y1
            else x0 <= x1

adjacents :: Position -> [Position]
adjacents p = [move GoUp, move GoLeft, move GoRight, move GoDown] <*> [p]

data Direction
    = GoUp
    | GoLeft
    | GoRight
    | GoDown
    deriving (Show, Eq, Ord)

move :: Direction -> Position -> Position
move d (Position (x, y)) =
    case d of
        GoUp    -> Position (x, y - 1)
        GoLeft  -> Position (x - 1, y)
        GoRight -> Position (x + 1, y)
        GoDown  -> Position (x, y + 1)

-- CAVE TILE
data CaveTile
    = Empty
    | Wall
    deriving (Show, Eq)

charToCaveTile :: Char -> CaveTile
charToCaveTile =
    \case
        '#' -> Wall
        '.' -> Empty
        'G' -> Empty
        'E' -> Empty

caveTileToChar :: CaveTile -> Char
caveTileToChar =
    \case
        Empty -> '.'
        Wall -> '#'

-- CAVE
type Cave = M.Map Position CaveTile

isEmpty :: Cave -> Position -> Bool
isEmpty c p = M.findWithDefault Wall p c == Empty

-- UNIT TYPE
data UnitType
    = Goblin
    | Elf
    deriving (Show, Eq)

targetOf :: UnitType -> UnitType
targetOf =
    \case
        Goblin -> Elf
        Elf -> Goblin

-- UNIT
data Unit = Unit
    { _unitId    :: String
    , _unitType  :: UnitType
    , _pos       :: Position
    , _hitPoints :: Integer
    } deriving (Show)

instance Eq Unit where
    (==) = (==) `on` _unitId

isAlive :: Unit -> Bool
isAlive Unit {..} = _hitPoints > 0

unitToChar :: Unit -> Char
unitToChar Unit {..} =
    case _unitType of
        Goblin -> 'G'
        Elf    -> 'E'

isOfType :: UnitType -> Unit -> Bool
isOfType t Unit {..} = _unitType == t

-- Turns Units into Walls and adds them to the existing Cave
-- Good for calculating range and movement
medusa :: [Unit] -> Cave -> Cave
medusa us = M.union $ M.fromList [(_pos u, Wall) | u <- us]

-- CONFIG
data Config = Config
    { _cave  :: Cave
    , _units :: [Unit]
    , _size  :: Size
    }

instance Show Config where
    show Config {..} = unlines . map row $ [0 .. height - 1]
      where
        Size (width, height) = _size
        row y = [char $ Position (x, y) | x <- [0 .. width - 1]]
        char p = fromMaybe (caveTileAt p) (unitAt p)
        unitAt p = unitToChar <$> find ((== p) . _pos) (filter isAlive _units)
        caveTileAt p = caveTileToChar (_cave M.! p)

-- FLOOD FILL
data FFResult = FFResult
    { distance           :: Integer
    , firstStepDirection :: Direction
    } deriving (Show, Eq, Ord)

type FloodFill = M.Map Position FFResult

floodFill :: Cave -> Position -> FloodFill
-- new approach, state monad to build the FF state using a stack of positions to visit
-- each stack entry has a position and a FFResult
-- the initial step is to get the empty adjacent positions p and pop them into the stack
-- then while the stack is not empty,
--      pop from stack, add to FF, push its emtpy adjacent positions into the stack, updating dist
-- extract FF at the end
floodFill c p = undefined

-- LENSES
makeLenses ''Unit

makeLenses ''Config

forEach_ :: MonadState s m => Getting (Sequenced r m) s a -> (a -> m r) -> m ()
forEach_ gs f = get >>= \s -> forMOf_ gs s f

-- GENERAL HELPERS
mapSnd :: (a -> b) -> (c, a) -> (c, b)
mapSnd f (c, a) = (c, f a)

-- SPECIFIC CODE
parseCave :: Size -> String -> Cave
parseCave size = M.fromList . map (mapSnd charToCaveTile) . addPosition size

parseUnits :: Size -> String -> [Unit]
parseUnits size = mapMaybe pairToUnit . addPosition size
  where
    pairToUnit (p, c) =
        case c of
            'G' -> Just $ Unit (show p) Goblin p 200
            'E' -> Just $ Unit (show p) Elf p 200
            _   -> Nothing

addPosition :: Size -> String -> [(Position, Char)]
addPosition (Size (width, height)) =
    zip [Position (x, y) | y <- [0 .. height - 1], x <- [0 .. width - 1]]

parseInput :: String -> Config
parseInput input = Config (parseCave size clean) (parseUnits size clean) size
  where
    size = Size (width, height)
    width = genericLength . (!! 0) . lines $ input
    height = genericLength . lines $ input
    clean = filter (/= '\n') input

combatRound :: State Config ()
combatRound = do
    sortUnits
    forEach_ (units . traverse) unitTurn
  where
    sortUnits = modifying units (sortOn _pos)

unitTurn :: Unit -> State Config ()
unitTurn unit =
    when (isAlive unit) $ do
        unitMove unit
        unitAttack unit

unitMove :: Unit -> State Config ()
unitMove Unit {..} = do
    targets <- getTargets _unitType
    positions <- join <$> targets `forM` rangePositions
    when (_pos `notElem` positions) $ do
        ff <- measureFrom _pos
        case L.head . sort . mapMaybe (`M.lookup` ff) $ positions of
            Just FFResult {..} -> moveUnit _unitId firstStepDirection
            Nothing            -> return ()
  where
    getTargets :: UnitType -> State Config [Unit]
    getTargets t =
        gets $ toListOf (units . traverse . filtered (isOfType $ targetOf t))
    rangePositions :: Unit -> State Config [Position]
    rangePositions Unit {..} = do
        cave <- gets (\Config {..} -> medusa (filter isAlive _units) _cave)
        return $ filter (isEmpty cave) (adjacents _pos)
    measureFrom :: Position -> State Config FloodFill
    measureFrom p = do
        cave <- gets (\Config {..} -> medusa (filter isAlive _units) _cave)
        return $ floodFill cave p
    moveUnit :: String -> Direction -> State Config ()
    moveUnit id d =
        modifying
            (units . traverse . filtered (views unitId (== id)) . pos)
            (move d)

unitAttack :: Unit -> State Config ()
-- identify targets in range
-- sort by HP and then by position (reading order)
-- pick the first, if any and reduce its HP by 3
unitAttack = undefined

combatOver :: State Config Bool
combatOver = (||) <$> allDead Goblin <*> allDead Elf
  where
    allDead :: UnitType -> State Config Bool
    allDead t =
        gets $ allOf (units . traverse . filtered (isOfType t)) (not . isAlive)

simulate :: Config -> (Config, Integer)
simulate = swap . runState (genericLength <$> (combatRound `untilM` combatOver))

scoreCombat :: (Config, Integer) -> Integer
scoreCombat (cfg, rounds) = rounds * totalHitPoints cfg
  where
    totalHitPoints = sum . toListOf (units . traverse . hitPoints)

outcome :: Config -> Integer
outcome = scoreCombat . simulate

main :: IO ()
main = do
    input <- parseInput <$> loadInput
    print $ outcome input
