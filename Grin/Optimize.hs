
module Grin.Optimize(grinPush,grinSpeculate) where

import qualified Data.Set as Set
import Control.Monad.State
import List
import Data.Monoid

import Grin.Grin
import Grin.Whiz
import C.Prims
import Support.FreeVars
import Stats
import Util.Graph
import Util.SetLike
import Atom
import Support.CanType


data PExp = PExp {
    pexpUniq :: Int,
    pexpBind :: Val,
    pexpExp  :: Exp,
    pexpProvides :: [Var],
    pexpDeps :: [Int]
    } deriving(Show)

instance Eq PExp where
    a == b = pexpUniq a == pexpUniq b

makeDeps :: [PExp] -> PExp -> PExp
makeDeps cs pexp = pexp { pexpProvides = freeVars (pexpBind pexp), pexpDeps = deps } where
    deps = [ pexpUniq c | c <- cs, not $ null $ fvs `intersect` pexpProvides c ]
    fvs = freeVars (pexpExp pexp)

justDeps :: [PExp] -> [Var] -> [Int]
justDeps cs fs = deps where
    deps = [ pexpUniq c | c <- cs, not $ null $ fs `intersect` pexpProvides c ]

-- | grinPush pushes the definitions of variables as far inward as they can go so
-- peephole optimizations have a better chance of firing. when the order of definitons
-- doesn't matter, it uses heuristics to decide which one to push to allow the most
-- peephole optimizations.

grinPush :: Stats -> Lam -> IO Lam
grinPush stats lam = ans where
    ans = do
        (ans,_) <- evalStateT (whiz subBlock doexp finalExp whizState lam) (1,[])
        return ans
    subBlock _ action = do
        (nn,x) <- get
        put (nn,mempty)
        r <- action
        (nn,_) <- get
        put (nn,x)
        return r
    doexp (v, exp) | isOmittable exp = do
        (nn,cv) <- get
        let npexp = makeDeps cv PExp { pexpUniq = nn, pexpBind = v, pexpExp = exp, pexpDeps = undefined, pexpProvides = undefined }
        put (nn+1,npexp:cv)
        return Nothing
    doexp (v, exp) = do
        exp' <- dropAny exp
        return $ Just (v,exp')
    finalExp (exp::Exp) = do
        exp' <- dropAny exp
        return (exp'::Exp)
    dropAny (exp::Exp) = do
        (nn,xs) <- get
        let graph = newGraph xs pexpUniq pexpDeps
            deps = justDeps xs (freeVars exp)
            reached = reachable graph deps
            dropped = case prefered reached exp of
                Just (x:_) | [] <- [ r | r <- reached, pexpUniq x `elem` pexpDeps r ] -> (reverse $ topSort $ newGraph (filter (/= x) reached) pexpUniq pexpDeps) ++ [x]
                _ -> reverse $ topSort $ newGraph reached pexpUniq pexpDeps
            ff pexp exp = pexpExp pexp :>>= pexpBind pexp :-> exp
        put (nn,[ x | x <- xs, pexpUniq x `notElem` (map pexpUniq reached) ])
        return (foldr ff exp dropped :: Exp)
    -- | preferentially pull definitons of the variable this returns right next to it as it admits a peephole optimization
    prefer (Store v@Var {}) = return v
    prefer (App fn [v@Var {}] _)  | fn == funcEval = return v
    prefer (App fn [v@Var {},_] _)  | fn == funcApply = return v
    prefer (Update _ v@Var {}) = return v
    prefer (Update v@Var {} _) = return v
    prefer _ = fail "no preference"
    prefered pexps exp = do
        v <- prefer exp
        return [ p | p <- pexps, v == pexpBind p]

isOmittable (Fetch {}) = True
isOmittable (Return {}) = True
isOmittable (Store (NodeC n _)) | n == tagHole = False
isOmittable (Store {}) = True
isOmittable Prim { expPrimitive = Primitive { primAPrim = aprim } } = aprimIsCheap aprim
isOmittable (Case x ds) = all isOmittable [ e | _ :-> e <- ds ]
isOmittable (e1 :>>= _ :-> e2) = isOmittable e1 && isOmittable e2
isOmittable _ = False


grinSpeculate :: Grin -> IO Grin
grinSpeculate grin = do
    let ss = findSpeculatable grin
    putStrLn "Speculatable:"
    mapM_ Prelude.print ss
    let (grin',stats) = runStatM (performSpeculate ss grin)
    Stats.printStat "Speculate" stats
    return grin'

mapBodyM f (x :-> y) = f y >>= return . (x :->)

mapExpExp f (a :>>= v :-> b) = do
    a <- f a
    b <- f b
    return (a :>>= v :-> b)
mapExpExp f (Case e as) = do
    as' <- mapM (mapBodyM f) as
    return (Case e as')
mapExpExp _ x = return x

performSpeculate specs grin = do
    let sset = Set.fromList (map tagFlipFunction specs)
    let f (a,l) = mapBodyM h l  >>= \l' -> return (a,l')
        h (Store (NodeC t xs)) | t `member` sset = do
            let t' = tagFlipFunction t
            mtick $ "Optimize.speculate.store.{" ++ show t'
            return (App t' xs TyNode :>>= n1 :-> Store n1)
        h (Update v (NodeC t xs)) | t `member` sset = do
            let t' = tagFlipFunction t
            mtick $ "Optimize.speculate.update.{" ++ show t'
            return (App t' xs TyNode :>>= n1 :-> Update v n1)
        h e = mapExpExp h e
    fs <- mapM f (grinFunctions grin)
    return grin { grinFunctions = fs }

findSpeculatable :: Grin -> [Atom]
findSpeculatable grin = ans where
    ans = [ x | Left (x,_) <- scc graph ]
    graph = newGraph [ (a,concatMap f (freeVars l)) | (a,_ :-> l) <- grinFunctions grin, isSpeculatable l, getType l == TyNode ] fst snd
    f t | tagIsSuspFunction t = [tagFlipFunction t]
        | tagIsFunction t = [t]
        | otherwise = []
    isSpeculatable Return {} = True
    isSpeculatable Store {} = True
    isSpeculatable (x :>>= _ :-> y) = isSpeculatable x && isSpeculatable y
    isSpeculatable (Case e as) = all isSpeculatable [ e | _ :-> e <- as]
    isSpeculatable Prim { expPrimitive = Primitive { primAPrim = APrim p _ } } = primIsConstant p
    isSpeculatable _ = False



