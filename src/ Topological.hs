-- Tools for working with Directed Acyclic Graphs 
-- using the topological sorting 
{-# LANGUAGE RankNtypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module topograph (
    G(..),
    runG,
    runG',
    -- * Transpose
    transpose,
    -- * Transitive reduction
    reduction,
    -- * Transitive closure
    closure,
    -- * DFS
    dfs,
    dfsTree,
    -- * All paths
    allPaths,
    allPaths',
    allPathsTree,
    -- * Path lengths
    shortestPathLengths,
    longestPathLengths,
    -- * Query
    edgesSet,
    adjacencyMap,
    adjacencyList,
    -- * Utilities
    pairs,
    treePairs,
)where 
    import  Data.Orphans 
    import  Prelude 
    import  Prelude.Compat 

    import Control.Monad.ST (ST, runST)
    import Data.Foldable    (for_)
    import Data.List        (sort)
    import Data.Map         (Map)
    import Data.Maybe       (catMaybes, mapMaybe)
    import Data.Monoid      (First (..))
    import Data.Ord         (Down (..))
    import Data.Set         (Set)
    
    import qualified Data.Graph                  as G
    import qualified Data.Map                    as M
    import qualified Data.Set                    as S
    import qualified Data.Tree                   as T
    import qualified Data.Vector                 as V
    import qualified Data.Vector.Unboxed         as U
    import qualified Data.Vector.Unboxed.Mutable as MU
-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

-- $setup
--
-- Graph used in examples:
--
-- <<dag-original.png>>
--
-- >>> let example :: Map Char (Set Char); example = M.map S.fromList $ M.fromList [('a', "bxde"), ('b', "d"), ('x', "de"), ('d', "e"), ('e', "")]
--
-- >>> :set -XRecordWildCards
-- >>> import Data.Monoid (All (..))
-- >>> import Data.Foldable (traverse_)
-- >>> import Data.List (elemIndex)
-- >>> import Data.Tree (Tree (..))
--
-- == Few functions to be used in examples
--
-- To make examples slightly shorter:
--
-- >>> let fmap2 = fmap . fmap
-- >>> let fmap3 = fmap . fmap2
-- >>> let traverse2_ = traverse_ . traverse_
-- >>> let traverse3_ = traverse_ . traverse2_
--
-- To display trees:
--
-- >>> let dispTree :: Show a => Tree a -> IO (); dispTree = go 0 where go i (T.Node x xs) = putStrLn (replicate (i * 2) ' ' ++ show x) >> traverse_ (go (succ i)) xs
--

--

-------------------------------------------------------------------------------
-- Graph
-------------------------------------------------------------------------------

-- | Graph representation.
--
-- The 'runG' creates a @'G' v i@ structure. Note, that @i@ is kept free,
-- so you cannot construct `i` which isn't in the `gVertices`.
-- Therefore operations, like `gFromVertex` are total (and fast).
--
-- === __Properties__
--
-- @'gVerticeCount' g = 'length' ('gVertices' g)@
--
-- >>> runG example $ \G {..} -> (length gVertices, gVerticeCount)
-- Right (5,5)
--
-- @'Just' ('gVertexIndex' g x) = 'elemIndex' x ('gVertices' g)@
--
-- >>> runG example $ \G {..} -> map (`elemIndex` gVertices) gVertices
-- Right [Just 0,Just 1,Just 2,Just 3,Just 4]
--
-- >>> runG example $ \G {..} -> map gVertexIndex gVertices
-- Right [0,1,2,3,4]
--
data G v i = G{
    gVertices :: [i]
    ,gFromVertices  :: i -> v
    ,gToVertices :: v -> Maybe i
    ,gEdges :: i -> [i]
    ,gdiff :: i -> i -> [i]
    ,gVerticesCount :: Int 
    ,gVertexIndex :: i -> Int 

}
-- | Run action on topologically sorted representation of the graph.
--
-- === __Examples__
--
-- ==== Topological sorting
--
-- >>> runG example $ \G {..} -> map gFromVertex gVertices
-- Right "axbde"
--
-- Vertices are sorted
--
-- >>> runG example $ \G {..} -> map gFromVertex $ sort gVertices
-- Right "axbde"
--
-- ==== Outgoing edges
--
-- >>> runG example $ \G {..} -> map (map gFromVertex . gEdges) gVertices
-- Right ["xbde","de","d","e",""]
--
-- Note: target indices are always larger than source vertex' index:
--
-- >>> runG example $ \G {..} -> getAll $ foldMap (\a -> foldMap (\b -> All (a < b)) (gEdges a)) gVertices
-- Right True
--
-- ==== Not DAG
--
-- >>> let loop = M.map S.fromList $ M.fromList [('a', "bx"), ('b', "cx"), ('c', "ax"), ('x', "")]
-- >>> runG loop $ \G {..} -> map gFromVertex gVertices
-- Left "abc"
--
-- >>> runG (M.singleton 'a' (S.singleton 'a')) $ \G {..} -> map gFromVertex gVertices
-- Left "aa"
--
runG
    :: forall v r. Ord v
    => Map v (Set v)                    -- ^ Adjacency Map
    -> (forall i. Ord i => G v i -> r)  -- ^ function on linear indices
    -> Either [v] r                     -- ^ Return the result or a cycle in the graph.
runG m f
    | Just l <- loop = Left (map (indices V.!) l)
    | otherwise      = Right (f g)
  where
    gr :: G.Graph
    r  :: G.Vertex -> ((), v, [v])
    _t  :: v -> Maybe G.Vertex

    (gr, r, _t) = G.graphFromEdges [ ((), v, S.toAscList us) | (v, us) <- M.toAscList m ]

    r' :: G.Vertex -> v
    r' i = case r i of (_, v, _) -> v

    topo :: [G.Vertex]
    topo = G.topSort gr

    indices :: V.Vector v
    indices = V.fromList (map r' topo)

    revIndices :: Map v Int
    revIndices = M.fromList $ zip (map r' topo) [0..]

    edges :: V.Vector [Int]
    edges = V.map
        (\v -> maybe
            []
            (\sv -> sort $ mapMaybe (\v' -> M.lookup v' revIndices) $ S.toList sv)
            (M.lookup v m))
        indices

    -- TODO: let's see if this check is too expensive
    loop :: Maybe [Int]
    loop = getFirst $ foldMap (\a -> foldMap (check a) (gEdges g a)) (gVertices g)
      where
        check a b
            | a < b     = First Nothing
            -- TODO: here we could use shortest path
            | otherwise = First $ case allPaths g b a of
                []      -> Nothing
                (p : _) -> Just p

    g :: G v Int
    g = G
        { gVertices     = [0 .. V.length indices - 1]
        , gFromVertex   = (indices V.!)
        , gToVertex     = (`M.lookup` revIndices)
        , gDiff         = \a b -> b - a
        , gEdges        = (edges V.!)
        , gVerticeCount = V.length indices
        , gVertexIndex  = id
        }

-- | Like 'runG' but returns 'Maybe'
runG'
    :: forall v r. Ord v
    => Map v (Set v)                    -- ^ Adjacency Map
    -> (forall i. Ord i => G v i -> r)  -- ^ function on linear indices
    -> Maybe r                          -- ^ Return the result or 'Nothing' if there is a cycle.
runG' m f = either (const Nothing) Just (runG m f)

-------------------------------------------------------------------------------
-- All paths
-------------------------------------------------------------------------------

-- | All paths from @a@ to @b@. Note that every path has at least 2 elements, start and end.
-- Use 'allPaths'' for the intermediate steps only.
--
-- See 'dfs', which returns all paths starting at some vertice.
-- This function returns paths with specified start and end vertices.
--
-- >>> runG example $ \g@G{..} -> fmap3 gFromVertex $ allPaths g <$> gToVertex 'a' <*> gToVertex 'e'
-- Right (Just ["axde","axe","abde","ade","ae"])
--
-- There are no paths from element to itself:
--
-- >>> runG example $ \g@G{..} -> fmap3 gFromVertex $ allPaths g <$> gToVertex 'a' <*> gToVertex 'a'
-- Right (Just [])
--
allPaths :: forall v i. Ord i => G v i -> i -> i -> [[i]]
allPaths g a b = map (\p -> a : p) (allPaths' g a b [b])

-- | 'allPaths' without begin and end elements.
--
-- >>> runG example $ \g@G{..} -> fmap3 gFromVertex $ allPaths' g <$> gToVertex 'a' <*> gToVertex 'e' <*> pure []
-- Right (Just ["xd","x","bd","d",""])
--
allPaths' :: forall v i. Ord i => G v i -> i -> i -> [i] -> [[i]]
allPaths' G {..} a b end = concatMap go (gEdges a) where
    go :: i -> [[i]]
    go i
        | i == b    = [end]
        | otherwise =
            let js :: [i]
                js = filter (<= b) $ gEdges i

                js2b :: [[i]]
                js2b = concatMap go js

            in map (i:) js2b

-- | Like 'allPaths' but return a 'T.Tree'.
-- All paths from @a@ to @b@. Note that every path has at least 2 elements, start and end,
--
-- Unfortunately, this is the same as @'dfs' g \<$> 'gToVertex' \'a\'@,
-- as in our example graph, all paths from @\'a\'@ end up in @\'e\'@.
--
-- <<dag-tree.png>>
--
-- >>> let t = runG example $ \g@G{..} -> fmap3 gFromVertex $ allPathsTree g <$> gToVertex 'a' <*> gToVertex 'e'
-- >>> fmap3 (T.foldTree $ \a bs -> if null bs then [[a]] else concatMap (map (a:)) bs) t
-- Right (Just (Just ["axde","axe","abde","ade","ae"]))
--
-- >>> fmap3 (S.fromList . treePairs) t
-- Right (Just (Just (fromList [('a','b'),('a','d'),('a','e'),('a','x'),('b','d'),('d','e'),('x','d'),('x','e')])))
--
-- >>> let ls = runG example $ \g@G{..} -> fmap3 gFromVertex $ allPaths g <$> gToVertex 'a' <*> gToVertex 'e'
-- >>> fmap2 (S.fromList . concatMap pairs) ls
-- Right (Just (fromList [('a','b'),('a','d'),('a','e'),('a','x'),('b','d'),('d','e'),('x','d'),('x','e')]))
--
-- 'Tree' paths show how one can explore the paths.
--
-- >>> traverse3_ dispTree t
-- 'a'
--   'x'
--     'd'
--       'e'
--     'e'
--   'b'
--     'd'
--       'e'
--   'd'
--     'e'
--   'e'
--
-- >>> traverse3_ (putStrLn . T.drawTree . fmap show) t
-- 'a'
-- |
-- +- 'x'
-- |  |
-- |  +- 'd'
-- |  |  |
-- |  |  `- 'e'
-- |  |
-- |  `- 'e'
-- ...
--
-- There are no paths from element to itself, but we'll return a
-- single root node, as 'Tree' cannot be empty.
--
-- >>> runG example $ \g@G{..} -> fmap3 gFromVertex $ allPathsTree g <$> gToVertex 'a' <*> gToVertex 'a'
-- Right (Just (Just (Node {rootLabel = 'a', subForest = []})))
--
allPathsTree :: forall v i. Ord i => G v i -> i -> i -> Maybe (T.Tree i)
allPathsTree G {..} a b = go a where
    go :: i -> Maybe (T.Tree i)
    go i
        | i == b    = Just (T.Node b [])
        | otherwise = case mapMaybe go $ filter (<= b) $ gEdges i of
            [] -> Nothing
            js -> Just (T.Node i js)

-------------------------------------------------------------------------------
-- DFS
-------------------------------------------------------------------------------

-- | Depth-first paths starting at a vertex.
--
-- >>> runG example $ \g@G{..} -> fmap3 gFromVertex $ dfs g <$> gToVertex 'x'
-- Right (Just ["xde","xe"])
--
dfs :: forall v i. Ord i => G v i -> i -> [[i]]
dfs G {..} = go where
    go :: i -> [[i]]
    go a = case gEdges a of
        [] -> [[a]]
        bs -> concatMap (\b -> map (a :) (go b)) bs

-- | like 'dfs' but returns a 'T.Tree'.
--
-- >>> traverse2_ dispTree $ runG example $ \g@G{..} -> fmap2 gFromVertex $ dfsTree g <$> gToVertex 'x'
-- 'x'
--   'd'
--     'e'
--   'e'
--
dfsTree :: forall v i. Ord i => G v i -> i -> T.Tree i
dfsTree G {..} = go where
    go :: i -> T.Tree i
    go a = case gEdges a of
        [] -> T.Node a []
        bs -> T.Node a $ map go bs

-------------------------------------------------------------------------------
-- Longest / shortest path
-------------------------------------------------------------------------------

-- | Shortest paths lengths starting from a vertex.
-- The resulting list is of the same length as 'gVertices'.
-- It's quite efficient to compute all shortest (or longest) paths' lengths
-- at once. Zero means that there are no path.
--
-- >>> runG example $ \g@G{..} -> shortestPathLengths g <$> gToVertex 'a'
-- Right (Just [0,1,1,1,1])
--
-- >>> runG example $ \g@G{..} -> shortestPathLengths g <$> gToVertex 'b'
-- Right (Just [0,0,0,1,2])
--
shortestPathLengths :: Ord i => G v i -> i -> [Int]
shortestPathLengths = pathLenghtsImpl min' where
    min' 0 y = y
    min' x y = min x y

-- | Longest paths lengths starting from a vertex.
-- The resulting list is of the same length as 'gVertices'.
--
-- >>> runG example $ \g@G{..} -> longestPathLengths g <$> gToVertex 'a'
-- Right (Just [0,1,1,2,3])
--
-- >>> runG example $ \G {..} -> map gFromVertex gVertices
-- Right "axbde"
--
-- >>> runG example $ \g@G{..} -> longestPathLengths g <$> gToVertex 'b'
-- Right (Just [0,0,0,1,2])
--
longestPathLengths :: Ord i => G v i -> i -> [Int]
longestPathLengths = pathLenghtsImpl max

pathLenghtsImpl :: forall v i. Ord i => (Int -> Int -> Int) -> G v i -> i -> [Int]
pathLenghtsImpl merge G {..} a = runST $ do
    v <- MU.replicate (length gVertices) (0 :: Int)
    go v (S.singleton a)
    v' <- U.freeze v
    pure (U.toList v')
  where
    go :: MU.MVector s Int -> Set i -> ST s ()
    go v xs = do
        case S.minView xs of
            Nothing       -> pure ()
            Just (x, xs') -> do
                c <- MU.unsafeRead v (gVertexIndex x)
                let ys = S.fromList $ gEdges x
                for_ ys $ \y ->
                    flip (MU.unsafeModify v) (gVertexIndex y) $ \d -> merge d (c + 1)
                go v (xs' `S.union` ys)

-------------------------------------------------------------------------------
-- Transpose
-------------------------------------------------------------------------------

-- | Graph with all edges reversed.
--
-- <<dag-transpose.png>>
--
-- >>> runG example $ adjacencyList . transpose
-- Right [('a',""),('b',"a"),('d',"abx"),('e',"adx"),('x',"a")]
--
-- === __Properties__
--
-- Commutes with 'closure'
--
-- >>> runG example $ adjacencyList . closure . transpose
-- Right [('a',""),('b',"a"),('d',"abx"),('e',"abdx"),('x',"a")]
--
-- >>> runG example $ adjacencyList . transpose . closure
-- Right [('a',""),('b',"a"),('d',"abx"),('e',"abdx"),('x',"a")]
--
-- Commutes with 'reduction'
--
-- >>> runG example $ adjacencyList . reduction . transpose
-- Right [('a',""),('b',"a"),('d',"bx"),('e',"d"),('x',"a")]
--
-- >>> runG example $ adjacencyList . transpose . reduction
-- Right [('a',""),('b',"a"),('d',"bx"),('e',"d"),('x',"a")]
--
transpose :: forall v i. Ord i => G v i -> G v (Down i)
transpose G {..} = G
    { gVertices     = map Down $ reverse gVertices
    , gFromVertex   = gFromVertex . getDown
    , gToVertex     = fmap Down . gToVertex
    , gEdges        = gEdges'
    , gDiff         = \(Down a) (Down b) -> gDiff b a
    , gVerticeCount = gVerticeCount
    , gVertexIndex  = \(Down a) -> gVerticeCount - gVertexIndex a - 1
    }
  where
    gEdges' :: Down i -> [Down i]
    gEdges' (Down a) = es V.! gVertexIndex a

    -- Note: in original order!
    es :: V.Vector [Down i]
    es = V.fromList $ map (map Down . revEdges) gVertices

    revEdges :: i -> [i]
    revEdges x = concatMap (\y -> [y | x `elem` gEdges y ]) gVertices


-------------------------------------------------------------------------------
-- Reduction
-------------------------------------------------------------------------------

-- | Transitive reduction.
--
-- Smallest graph,
-- such that if there is a path from /u/ to /v/ in the original graph,
-- then there is also such a path in the reduction.
--
-- The green edges are not in the transitive reduction:
--
-- <<dag-reduction.png>>
--
-- >>> runG example $ \g -> adjacencyList $ reduction g
-- Right [('a',"bx"),('b',"d"),('d',"e"),('e',""),('x',"d")]
--
-- Taking closure first doesn't matter:
--
-- >>> runG example $ \g -> adjacencyList $ reduction $ closure g
-- Right [('a',"bx"),('b',"d"),('d',"e"),('e',""),('x',"d")]
--
reduction :: Ord i => G v i -> G v i
reduction = transitiveImpl (== 1)

-------------------------------------------------------------------------------
-- Closure
-------------------------------------------------------------------------------

-- | Transitive closure.
--
-- A graph,
-- such that if there is a path from /u/ to /v/ in the original graph,
-- then there is an edge from /u/ to /v/ in the closure.
--
-- The purple edge is added in a closure:
--
-- <<dag-closure.png>>
--
-- >>> runG example $ \g -> adjacencyList $ closure g
-- Right [('a',"bdex"),('b',"de"),('d',"e"),('e',""),('x',"de")]
--
-- Taking reduction first, doesn't matter:
--
-- >>> runG example $ \g -> adjacencyList $ closure $ reduction g
-- Right [('a',"bdex"),('b',"de"),('d',"e"),('e',""),('x',"de")]
--
closure :: Ord i => G v i -> G v i
closure = transitiveImpl (/= 0)

transitiveImpl :: forall v i. Ord i => (Int -> Bool) -> G v i -> G v i
transitiveImpl pre g@G {..} = g { gEdges = gEdges' } where
    gEdges' :: i -> [i]
    gEdges' a = es V.! gVertexIndex a

    es :: V.Vector [i]
    es = V.fromList $ map f gVertices where
        f :: i -> [i]
        f x = catMaybes $ zipWith edge gVertices (longestPathLengths g x)

        edge y i
            | pre i     = Just y
            | otherwise = Nothing

-------------------------------------------------------------------------------
-- Display
-------------------------------------------------------------------------------

-- | Recover adjacency map representation from the 'G'.
--
-- >>> runG example adjacencyMap
-- Right (fromList [('a',fromList "bdex"),('b',fromList "d"),('d',fromList "e"),('e',fromList ""),('x',fromList "de")])
--
adjacencyMap :: Ord v => G v i -> Map v (Set v)
adjacencyMap G {..} = M.fromList $ map f gVertices where
    f x = (gFromVertex x, S.fromList $ map gFromVertex $ gEdges x)

-- | Adjacency list representation of 'G'.
--
-- >>> runG example adjacencyList
-- Right [('a',"bdex"),('b',"d"),('d',"e"),('e',""),('x',"de")]
--
adjacencyList :: Ord v => G v i -> [(v, [v])]
adjacencyList = flattenAM . adjacencyMap

flattenAM :: Map a (Set a) -> [(a, [a])]
flattenAM = map (fmap S.toList) . M.toList

-- | Edges set.
--
-- >>> runG example $ \g@G{..} -> map (\(a,b) -> [gFromVertex a, gFromVertex b]) $  S.toList $ edgesSet g
-- Right ["ax","ab","ad","ae","xd","xe","bd","de"]
--
edgesSet :: Ord i => G v i -> Set (i, i)
edgesSet G {..} = S.fromList
    [ (x, y)
    | x <- gVertices
    , y <- gEdges x
    ]

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

-- | Unwrap 'Down'.
getDown :: Down a -> a
getDown (Down a) = a

-- | Like 'pairs' but for 'T.Tree'.
treePairs :: T.Tree a -> [(a,a)]
treePairs (T.Node i js) =
    [ (i, j) | T.Node j _ <- js ] ++ concatMap treePairs js

-- | Consequtive pairs.
--
-- >>> pairs [1..10]
-- [(1,2),(2,3),(3,4),(4,5),(5,6),(6,7),(7,8),(8,9),(9,10)]
--
-- >>> pairs []
-- []
--
pairs :: [a] -> [(a, a)]
pairs [] = []
pairs xs = zip xs (tail xs)











