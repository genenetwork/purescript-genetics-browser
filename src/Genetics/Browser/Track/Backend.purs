module Genetics.Browser.Track.Backend where

import Prelude

import Color (Color, black)
import Color.Scheme.Clrs (aqua, blue, fuchsia, green, lime, maroon, navy, olive, orange, purple, red, teal, yellow)
import Control.Alt ((<|>))
import Control.Monad.Aff (Aff)
import Control.Monad.Eff.Exception (error)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Reader (class MonadReader, ask)
import Data.Argonaut (Json, _Array, _Number, _Object, _String)
import Data.Array as Array
import Data.Filterable (class Filterable, filterMap)
import Data.Foldable (class Foldable, fold, foldMap, foldl, maximum)
import Data.Lens ((^?))
import Data.Lens.Index (ix)
import Data.List (List(..))
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(Just, Nothing), fromMaybe)
import Data.Monoid (class Monoid, mempty)
import Data.Monoid.Additive (Additive(..))
import Data.Newtype (class Newtype, alaF, unwrap)
import Data.Ord.Max (Max(..))
import Data.Record as Record
import Data.Semigroup.Foldable (foldMap1)
import Data.Symbol (SProxy(..))
import Data.Traversable (class Traversable, scanl, traverse)
import Data.Tuple (Tuple(Tuple), fst, snd, uncurry)
import Data.Unfoldable (class Unfoldable, singleton)
import Data.Unfoldable as Unfoldable
import Data.Variant (class Contractable, Variant)
import Data.Variant as Variant
import Genetics.Browser.Types (Bp(Bp), ChrId(ChrId), Point)
import Genetics.Browser.View (Pixels)
import Graphics.Drawing (Drawing, circle, fillColor, filled, outlineColor, outlined, rectangle, scale, translate)
import Graphics.Drawing as Drawing
import Graphics.Drawing.Font (font, sansSerif)
import Network.HTTP.Affjax as Affjax
import Type.Prelude (class IsSymbol, class RowLacks)
import Unsafe.Coerce (unsafeCoerce)

type Frame a = { padding :: Pixels, width :: Pixels, contents :: a }

type ChrCtx r = Map ChrId (Record r)

type ChrFrames r a = ChrCtx (frame :: Frame a | r)

totalSize :: forall r.
             ChrCtx (size :: Bp | r)
          -> Bp
totalSize chrCtx = alaF Additive foldMap _.size chrCtx


newtype Normalized a = Normalized a

derive instance newtypeNormalized :: Newtype (Normalized a) _

normalizePoint :: { width :: Number
                  , height :: Number }
               -> Point
               -> Normalized Point
normalizePoint {width, height} {x, y} = Normalized { x: x', y: y' }
  where x' = x / width
        y' = y / height

normPoint :: Point -> Maybe (Normalized Point)
normPoint p@{x, y}
  | x < 0.0 || x > 1.0 = Nothing
  | y < 0.0 || y > 1.0 = Nothing
  | otherwise = Just $ Normalized p

nPointToFrame :: Pixels -> Pixels -> Normalized Point -> Point
nPointToFrame w h (Normalized p) = {x: p.x * w, y: p.y * h}


-- A renderer draws a single value to a normalized "canvas",
-- i.e. the whole chromosome is located in x = (0.0, 1.0),
-- and the whole track height in y = (0.0, 1.0).
-- It can fail if the given feature for some reason cannot be rendered,
-- either because the feature lacks information, or because the context lacks something.
type PureRenderer a = a -> Maybe { drawing :: Drawing
                                 , point   :: Normalized Point
                                 }


tagRenderer :: forall a sym r1 r2.
               RowCons sym a r1 r2
            => IsSymbol sym
            => SProxy sym
            -> PureRenderer a
            -> PureRenderer (Variant r2)
tagRenderer sym renderer var = Variant.prj sym var >>= renderer


combineRenderers :: forall r1 r2 r3.
                    Union r1 r2 r3
                 => Contractable r3 r1
                 => Contractable r3 r2
                 => PureRenderer (Variant r1)
                 -> PureRenderer (Variant r2)
                 -> PureRenderer (Variant r3)
combineRenderers r1 r2 var = (Variant.contract var >>= r1) <|>
                             (Variant.contract var >>= r2)


type GWASFeature r = { score :: Number
                     , pos :: Bp
                     , chrId :: ChrId | r }

mkGwasRenderer :: forall m rf rctx.
                  MonadReader (ChrCtx (size :: Bp, color :: Color | rctx)) m
               -- => MonadError Unit m
               => {min :: Number, max :: Number}
               -> m (PureRenderer (GWASFeature rf))
mkGwasRenderer {min, max} = do
  ctx <- ask
  let renderer f = do
        size <- _.size <$> Map.lookup f.chrId ctx
        color <- _.color <$> Map.lookup f.chrId ctx
        let r = 2.2
            x = unwrap $ f.pos / size
            y = (f.score - min) / (max - min)
            c = circle x y r
            out = outlined (outlineColor color) c
            fill = filled (fillColor color) c
            drawing = out <> fill

        point <- normPoint {x, y}
        pure { drawing, point }

  pure renderer



-- A single Frame that contains all data that is required to draw it
type ReadyFrame a = { width :: Pixels
                    , padding :: Pixels
                    , height :: Pixels
                    , contents :: a }


pureRender :: forall f a.
              Filterable f
           => PureRenderer a
           -> f a
           -> f { drawing :: Drawing, point :: Normalized Point }
pureRender r as = filterMap r as



-- TODO simplify these two functions by extracting `padding` and `height` to another argument;
-- after all, only `width` changes per frame
drawPureFrame :: forall f r.
                 Foldable f
              => f { drawing :: Drawing, point :: Normalized Point | r }
              -> { width :: Pixels, padding :: Pixels, height :: Pixels }
              -> Drawing
drawPureFrame fs { width, padding, height } = foldMap render' fs
  where render' {drawing, point} =
            let {x,y} = nPointToFrame (width - padding * 2.0) height $ point
            in translate (x + padding) y drawing


-- Draw a collection of , lined up one after another
drawPureFrames :: forall a.
                  Array (Tuple (Array { drawing :: Drawing, point :: Normalized Point })
                               { width :: Pixels, padding :: Pixels, height :: Pixels })
               -> Drawing
drawPureFrames frames = fold $ Array.zipWith (\o d -> translate o 0.0 d) os drawings'
  where os = Array.cons 0.0 (framesOffsets $ snd <$> frames) -- add 0.0 since scanl in framesOffsets doesn't include seed
        drawings' = map (uncurry drawPureFrame) frames




framesOffsets :: forall f r.
                 Traversable f
              => f { width :: Pixels | r }
              -> f Pixels
framesOffsets fs = scanl (\o {width} -> width + o) 0.0 fs


insertFrame :: forall r a.
               RowLacks "frame" r
            => a
            -> { | r }
            -> { frame :: a | r }
insertFrame = Record.insert (SProxy :: SProxy "frame")


createFrames :: forall r a.
                RowLacks "frame" (size :: Bp | r)
             => Pixels
             -> Pixels
             -> Map ChrId {size :: Bp | r}
             -> Map ChrId a
             -> Map ChrId { size :: Bp, frame :: Frame a | r }
createFrames totalWidth padding sizes as = zipMapsWith zippy sizes as
  where ts = totalSize sizes
        mkWidth size = (unwrap $ size / ts) * totalWidth
        mkFrame' {size} a = { padding, width: mkWidth size, contents: a }
        zippy r a = insertFrame (mkFrame' r a) r




intersection :: forall k a b.
                Ord k
             => Map k a
             -> Map k b
             -> Map k a
intersection a b = Map.filterKeys (flip Map.member b) a

zipMaps :: forall k a b.
           Ord k
        => Map k a
        -> Map k b
        -> Map k (Tuple a b)
zipMaps a b =
  let kas = Array.unzip $ Map.toAscUnfoldable $ a `intersection` b
      kbs = Array.unzip $ Map.toAscUnfoldable $ b `intersection` a
      kabs = uncurry Array.zip $ map (Array.zip (snd kas)) kbs
  in Map.fromFoldable kabs


zipMapsWith :: forall k a b c.
               Ord k
            => (a -> b -> c)
            -> Map k a
            -> Map k b
            -> Map k c
zipMapsWith f a b = uncurry f <$> zipMaps a b

groupToChrs :: forall a f rData.
               Monoid (f {chrId :: ChrId | rData})
            => Foldable f
            => Applicative f
            => f { chrId :: ChrId | rData }
            -> Map ChrId (f { chrId :: ChrId | rData })
groupToChrs = foldl (\chrs r@{chrId} -> Map.alter (add r) chrId chrs ) mempty
  where add :: { chrId :: ChrId | rData } -> Maybe _ -> Maybe _
        add x Nothing   = Just $ pure x
        add x (Just xs) = Just $ pure x <> xs


chrFrames :: forall a.
             _
          -> Pixels
          -> Pixels
          -> Map ChrId a
          -> Map ChrId { size :: Bp
                       , frame :: { padding :: Pixels
                                  , width :: Pixels
                                  , contents :: a
                                  }
                       }
chrFrames ctx w p as = createFrames w p chrCtx' as
  where chrCtx' = Map.filterKeys (\k -> k `Map.member` as) ctx


mouseChrFrames = chrFrames mouseChrCtx


addHeight :: forall a r.
             Pixels
          -> Map ChrId { size :: Bp
                       , frame :: { padding :: Pixels
                                  , width :: Pixels
                                  , contents :: a
                                  }
                       | r
                       }
          -> Map ChrId { size :: Bp
                       , frame :: (ReadyFrame a)
                       | r }
addHeight h fs = map f fs
  where f entry = entry { frame = Record.insert (SProxy :: SProxy "height") h entry.frame }



fetchJSON :: forall a.
             (Json -> Maybe a)
          -> String
          -> Aff _ (Array a)
fetchJSON p url = do
  json <- _.response <$> Affjax.get url

  case json ^? _Array of
    Nothing -> throwError $ error "Parse error: JSON is not an array"
    Just as -> case traverse p as of
      Nothing -> throwError $ error "Failed to parse JSON features"
      Just fs -> pure $ fs


gemmaJSONParse :: Json -> Maybe (GWASFeature ())
gemmaJSONParse j = do
  obj <- j ^? _Object
  chrId <- ChrId <$> obj ^? ix "chr" <<< _String
  pos   <- Bp    <$> obj ^? ix "ps"  <<< _Number
  score <-           obj ^? ix "af"  <<< _Number
  pure {pos, score, chrId}



fetchGemmaJSON :: String -> Aff _ (Array (GWASFeature ()))
fetchGemmaJSON = fetchJSON gemmaJSONParse


type GeneRow' r = ( geneID :: String
                  , desc :: String
                  , start :: Bp
                  , end :: Bp
                  , name :: String | r )

type Gene' r = Record (GeneRow' r)


type GeneRow r = ( geneID :: String
                 , desc :: String
                 , start :: Bp
                 , end :: Bp
                 , name :: String
                 , chrId :: ChrId | r )

type Gene r = Record (GeneRow r)



gene'JSONParse :: Json -> Maybe (Gene' ())
gene'JSONParse j = do
  obj    <- j ^? _Object
  geneID <- obj ^? ix "Gene stable ID" <<< _String
  desc   <- obj ^? ix "Gene description" <<< _String
  name   <- obj ^? ix "Gene name" <<< _String
  start  <- Bp    <$> obj ^? ix "Gene start (bp)"  <<< _Number
  end    <- Bp    <$> obj ^? ix "Gene end (bp)"  <<< _Number
  pure {geneID, desc, name, start, end}



geneJSONParse :: Json -> Maybe (Gene ())
geneJSONParse j = do
  obj    <- j ^? _Object
  geneID <- obj ^? ix "Gene stable ID" <<< _String
  desc   <- obj ^? ix "Gene description" <<< _String
  name   <- obj ^? ix "Gene name" <<< _String
  start  <- Bp    <$> obj ^? ix "Gene start (bp)"  <<< _Number
  end    <- Bp    <$> obj ^? ix "Gene end (bp)"  <<< _Number
  chrId  <- ChrId <$> obj ^? ix "ChrId" <<< _String
  pure {geneID, desc, name, start, end, chrId}


fetchGene'JSON :: String -> Aff _ (Array (Gene' ()))
fetchGene'JSON = fetchJSON gene'JSONParse


geneFetchChrId :: forall r.
                  RowLacks "chrId" (GeneRow' r)
               => Gene' r
               -> Aff _ (Gene r)
geneFetchChrId gene = do
  let url = "http://rest.ensembl.org/lookup/id/" <>
            gene.geneID <> "?content-type=application/json"

  res <- _.response <$> Affjax.get url

  let chrId :: _
      chrId = do
        obj <- res ^? _Object
        ChrId <$> obj ^? ix "seq_region_name" <<< _String

  case chrId of
    Nothing  -> throwError $ error $ "Could not find chrId for gene " <> gene.geneID
    Just chr -> pure $ Record.insert (SProxy :: SProxy "chrId") chr gene


fetchGeneJSONEnsembl :: String -> Aff _ (Array (Gene ()))
fetchGeneJSONEnsembl url = traverse geneFetchChrId =<< fetchJSON gene'JSONParse url


fetchGeneJSON :: String -> Aff _ (Array (Gene ()))
fetchGeneJSON = fetchJSON geneJSONParse


mkGeneRenderer :: forall m rf rctx.
                  MonadReader (ChrCtx (size :: Bp | rctx)) m
               => m (PureRenderer (Gene rf))
mkGeneRenderer = do
  ctx <- ask

  let font' = font sansSerif 12 mempty
  let renderer f = do
        size <- _.size <$> Map.lookup f.chrId ctx
        let rad = 20.0
            lHand = unwrap $ f.start / size
            rHand = unwrap $ f.end / size
            w = (rHand - lHand) * unwrap size
            x = lHand + (rHand - lHand)
            y = 0.5
            rect = rectangle lHand (y - rad/2.0) w (rad/2.0)
            out = outlined (outlineColor red) rect
            fill = filled (fillColor maroon) rect
            -- the canvas is flipped so y-axis increases upward, need to flip the text too
            text' = scale 1.0 (-1.0)
                    $ Drawing.text font' x (y-0.25) (fillColor black) f.desc
            drawing = out <> fill <> text'

        point <- normPoint {x, y}
        pure { drawing, point }

  pure renderer


shiftRendererMinY :: forall rf.
                      RowLacks "minY" rf
                   => Number
                   -> { min :: Number, max :: Number }
                   -> PureRenderer (Record rf)
                   -> PureRenderer (Record (minY :: Number | rf))
shiftRendererMinY dist s render f = do
  {drawing, point} <- render (Record.delete (SProxy :: SProxy "minY") f)
  let {x,y} = unwrap point
      normY = (s.max - f.minY) / (s.max - s.min)
      y' = min (y + normY - dist) 1.0
  point' <- normPoint {x, y: y'}
  pure {drawing, point: point'}


bumpedGeneRenderer :: forall rf.
                      RowLacks "minY" (GeneRow rf)
                   => { min :: Number, max :: Number }
                   -> PureRenderer (Gene rf)
                   -> PureRenderer (Gene (minY :: Number | rf))
bumpedGeneRenderer s = shiftRendererMinY 0.05 s


bumpGenes :: forall rGene rGWAS.
             RowLacks "minY" (GeneRow rGene)
          => Map ChrId (List (GWASFeature rGWAS))
          -> Map ChrId (List (Gene rGene))
          -> Map ChrId (List (Gene (minY :: Number | rGene)))
bumpGenes = zipMapsWith (map <<< bumpGene)
  where maxScoreIn :: Bp -> Bp -> List (GWASFeature rGWAS) -> Number
        maxScoreIn l r gwas = fromMaybe 0.5 $ maximum
                              $ map (\g -> if g.pos >= l && g.pos <= r
                                           then g.score else 0.0) gwas
        bumpGene :: List (GWASFeature rGWAS) -> Gene rGene -> Gene (minY :: Number | rGene)
        bumpGene l g = let minY = maxScoreIn g.start g.end l
                       in Record.insert (SProxy :: SProxy "minY") minY g



drawData :: forall f a.
            Foldable f
         => { w :: Pixels, h :: Pixels, p :: Pixels, y :: Pixels }
         -> PureRenderer a
         -> Map ChrId (f a)
         -> Array ChrId
         -> Drawing
drawData {w,h,p,y} renderer dat chrs =
  let features :: Map ChrId (Array a)
      features = map Array.fromFoldable
                 $ Map.filterKeys (\k -> k `Array.elem` chrs) dat

      readyFrames :: Map ChrId { size :: Bp, frame :: ReadyFrame (Array a) }
      readyFrames = addHeight h $ mouseChrFrames w p features

      toDraw :: Array (ReadyFrame (Array a))
      toDraw = _.frame  <$> (filterMap (\chr -> Map.lookup chr readyFrames) chrs)

  in translate 0.0 (h-y) $ scale 1.0 (-1.0) $ drawFrames toDraw renderer


{-
drawGenes :: forall r.
             { w :: Number, h :: Number
             , p :: Number, y :: Number }
          -> List (Gene r)
          -> Array ChrId
          -> Drawing
drawGenes pos dat chrs = drawData pos renderer (groupToChrs dat) chrs
  where renderer = mkGeneRenderer mouseChrCtx


drawGemma :: forall r.
             { w :: Number, h :: Number
             , p :: Number, y :: Number }
          -> { min :: Number, max :: Number }
          -> List (GWASFeature r)
          -> Array ChrId
          -> Drawing
drawGemma pos s dat chrs = drawData pos renderer (groupToChrs dat) chrs
  where colorsCtx = zipMapsWith (\r {color} -> Record.insert (SProxy :: SProxy "color") color r)
                    mouseChrCtx mouseColors
        renderer :: PureRenderer (GWASFeature r)
        renderer = mkGwasRenderer s colorsCtx


drawBoth :: forall r.
            { w :: Number, h :: Number
            , p :: Number, y :: Number }
         -> { min :: Number, max :: Number }
         -> Map ChrId (List (Variant ("Gene" :: Gene (), "GWAS" :: GWASFeature ())))
         -> Array ChrId
         -> Drawing
drawBoth pos s dat chrs = drawData pos renderer dat chrs
  where geneR :: PureRenderer (Variant ("Gene" :: Gene ()))
        geneR = tagRenderer (SProxy :: SProxy "Gene") $ mkGeneRenderer mouseChrCtx
        gemmaR :: PureRenderer (Variant ("GWAS" :: GWASFeature ()))
        gemmaR = tagRenderer (SProxy :: SProxy "GWAS") $ mkGwasRenderer s colorsCtx
        colorsCtx = zipMapsWith (\r {color} -> Record.insert (SProxy :: SProxy "color") color r)
                    mouseChrCtx mouseColors
        renderer = combineRenderers geneR gemmaR
-}


mouseChrIds :: Array ChrId
mouseChrIds =
            [ (ChrId "1")
            , (ChrId "2")
            , (ChrId "3")
            , (ChrId "4")
            , (ChrId "5")
            , (ChrId "6")
            , (ChrId "7")
            , (ChrId "8")
            , (ChrId "9")
            , (ChrId "10")
            , (ChrId "11")
            , (ChrId "12")
            , (ChrId "13")
            , (ChrId "14")
            , (ChrId "15")
            , (ChrId "16")
            , (ChrId "17")
            , (ChrId "18")
            , (ChrId "19")
            , (ChrId "X")
            , (ChrId "Y")
            ]

mouseChrs :: Map ChrId Bp
mouseChrs = Map.fromFoldable $ Array.zip mouseChrIds $
            [ (Bp 195471971.0)
            , (Bp 182113224.0)
            , (Bp 160039680.0)
            , (Bp 156508116.0)
            , (Bp 151834684.0)
            , (Bp 149736546.0)
            , (Bp 145441459.0)
            , (Bp 129401213.0)
            , (Bp 124595110.0)
            , (Bp 130694993.0)
            , (Bp 122082543.0)
            , (Bp 120129022.0)
            , (Bp 120421639.0)
            , (Bp 124902244.0)
            , (Bp 104043685.0)
            , (Bp 98207768.0)
            , (Bp 94987271.0)
            , (Bp 90702639.0)
            , (Bp 61431566.0)
            , (Bp 17103129.0)
            , (Bp 9174469.0)
            ]

mouseColors :: ChrCtx (color :: Color)
mouseColors = Map.fromFoldable $ Array.zip mouseChrIds $ map (\x -> {color: x})
              [ navy, blue, aqua, teal, olive
              , green, lime, yellow, orange, red
              , maroon, fuchsia, purple, navy, blue
              , aqua, teal, olive, green, lime
              , yellow ]


mouseChrCtx :: ChrCtx (size :: Bp)
mouseChrCtx = map (\size -> { size }) mouseChrs


mouseChrSize :: Bp -> ChrId -> Bp
mouseChrSize def chr = fromMaybe def $ Map.lookup chr mouseChrs
